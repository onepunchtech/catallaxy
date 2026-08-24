//! What a cluster was built to be, and whether it still is.
//!
//! `lab up` creates a cluster that is missing and, before this, only checked
//! that an existing one existed. It compared two of roughly twelve declared
//! fields, so changing a port, a volume, an apiserver arg, a subnet or a CNI
//! flag in Nix produced a green run and an unchanged cluster, while
//! `executor.rs` and the docs both promised idempotent convergence.
//!
//! Most of those fields cannot be read back off a live k3d cluster without
//! parsing k3d's own implementation details — `extraApiServerArgs` renders
//! into the server container's command line, the CNI flags are only inferable
//! from workload presence. A drift check that silently cannot see a field is
//! the same bug in a new place, so instead of guessing, the shape a cluster
//! was built from is recorded when it is built and compared against the
//! declaration on the next run. That covers every field exactly.
//!
//! The corollary matters: no record is not "no drift". A cluster built by an
//! older catallaxy, or on another machine, cannot be verified at all, and that
//! is its own answer rather than a pass.

use serde::{Deserialize, Serialize};

use super::cluster::ClusterSpec;

/// Bumped when the recorded shape stops meaning what it did, so an old record
/// reads as unverifiable rather than as a spurious drift report.
///
/// 2 added `provisioner`. A record written before it has no provisioner to
/// compare, and defaulting one would either invent agreement or report drift
/// on a cluster nobody touched.
pub const SCHEMA_VERSION: u32 = 2;

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClusterShape {
    pub schema_version: u32,
    /// Which provisioner built it. Recorded because the fields worth
    /// comparing differ by provisioner, and because changing it is not a
    /// change to a cluster, it is a different cluster.
    #[serde(default)]
    pub provisioner: String,
    pub control_planes: u32,
    pub workers: u32,
    pub distribution: String,
    pub version: String,
    pub pod_subnet: String,
    pub service_subnet: String,
    pub image: Option<String>,
    pub network: Option<String>,
    pub no_traefik: bool,
    pub no_service_lb: bool,
    pub no_flannel: bool,
    /// Defaulted rather than versioned: a record written before this field
    /// existed describes a cluster where k3s's local-path-provisioner was
    /// never disabled, and `false` says exactly that. Enabling openebs on
    /// such a cluster then reads as drift, which it is.
    #[serde(default)]
    pub no_local_storage: bool,
    pub ports: Vec<String>,
    pub extra_api_server_args: Vec<String>,
    pub extra_volumes: Vec<String>,
    pub auto_deploy_manifests: Vec<String>,
}

impl ClusterShape {
    pub fn of(spec: &ClusterSpec) -> Self {
        let shape = ClusterShape {
            schema_version: SCHEMA_VERSION,
            provisioner: format!("{:?}", spec.provisioner).to_lowercase(),
            control_planes: spec.kubernetes.control_planes,
            workers: spec.kubernetes.workers,
            distribution: spec.kubernetes.distribution.clone(),
            version: spec.kubernetes.version.clone(),
            pod_subnet: spec.network.pod_subnet.clone(),
            service_subnet: spec.network.service_subnet.clone(),
            ..ClusterShape::default()
        };

        // The k3d block describes how k3d builds a cluster. Recording it for a
        // provisioner that never saw those options wrote nine fields of
        // fiction into the record: `noTraefik: true` for a distribution that
        // ships no Traefik, and worse, the apiserver args and volume mounts
        // k3d would have rendered for OIDC and PKI, asserting that a cluster
        // was configured in a way it never was.
        match spec.provisioner {
            crate::domain::ProvisionerKind::K3d => shape.with_k3d(&spec.provisioner_config.k3d),
            _ => shape,
        }
    }

    fn with_k3d(self, k3d: &crate::domain::cluster::K3dConfig) -> Self {
        ClusterShape {
            image: k3d.image.clone(),
            network: k3d.network.clone(),
            no_traefik: k3d.no_traefik,
            no_service_lb: k3d.no_service_lb,
            no_flannel: k3d.no_flannel,
            no_local_storage: k3d.no_local_storage,
            ports: k3d.ports.clone(),
            extra_api_server_args: k3d.extra_api_server_args.clone(),
            extra_volumes: k3d
                .extra_volumes
                .iter()
                .map(|v| format!("{}:{}", v.host_path, v.container_path))
                .collect(),
            auto_deploy_manifests: k3d
                .auto_deploy_manifests
                .iter()
                .map(|m| m.name.clone())
                .collect(),
            ..self
        }
    }
}

/// One field's answer. There is no "could not tell" variant because the
/// comparison is against a record rather than a live cluster: either the
/// record is there and every field has an answer, or it is absent and the
/// caller refuses outright.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FieldVerdict {
    Matches,
    Drifted { declared: String, actual: String },
}

/// How a drifted field can be brought back into line, cheapest first.
///
/// A k3d node keeps its datastore in a docker volume and the image pins only
/// the k3s binary, so replacing a container against the same volume keeps the
/// cluster's workloads, PVCs and PVs. Only the two fields baked in at first
/// init need a new cluster.
///
/// Removing workers is deliberately absent: k3d deletes a node without
/// draining it, and nothing here drains or cordons.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fix {
    /// Grow the cluster. Nothing is interrupted.
    AddWorkers(u32),
    AddServers(u32),
    /// Replace the node container against its existing state volume. The
    /// cluster survives; its API is briefly unavailable while the container
    /// restarts, unless there are enough servers to roll one at a time.
    ReplaceNode,
    /// Recreate the loadbalancer, which holds no state at all.
    ReplaceLoadBalancer,
    /// Nothing about the running cluster changes. `cluster.kubernetes.version`
    /// selects which generated schemas the manifests are typed against; the
    /// node image is what decides the Kubernetes a cluster actually runs.
    /// Recorded and reported so the change is visible, but there is no node
    /// work, and pretending there was is how a replacement ran with the same
    /// image and then wrote a record claiming the version had moved.
    RebuildOnly,
    /// Nothing short of a different cluster satisfies it: the pod and service
    /// CIDRs are written into the datastore when it is first initialised, and
    /// the distribution is a different thing entirely.
    NewCluster,
}

impl Fix {
    /// What it costs, for a message an operator has to act on.
    pub fn cost(self) -> &'static str {
        match self {
            Fix::AddWorkers(_) | Fix::AddServers(_) => "adds nodes, interrupts nothing",
            Fix::ReplaceNode => "replaces the node, keeping its data; the API pauses briefly",
            Fix::ReplaceLoadBalancer => "replaces the loadbalancer, which holds no state",
            Fix::RebuildOnly => {
                "changes which schemas the manifests are typed against, not the cluster"
            }
            Fix::NewCluster => "needs a new cluster, so everything on this one is lost",
        }
    }

    /// Whether `lab up` can perform it without being asked twice.
    pub fn is_in_place(self) -> bool {
        !matches!(self, Fix::NewCluster)
    }
}

/// Every field that no longer matches, keyed by the Nix option path, because
/// that is what the error has to name for the operator to act on it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct DriftReport {
    pub fields: Vec<(&'static str, FieldVerdict, Option<Fix>)>,
}

impl DriftReport {
    pub fn drifted(&self) -> Vec<(&'static str, &str, &str)> {
        self.fields
            .iter()
            .filter_map(|(option, verdict, _)| match verdict {
                FieldVerdict::Drifted { declared, actual } => {
                    Some((*option, declared.as_str(), actual.as_str()))
                }
                FieldVerdict::Matches => None,
            })
            .collect()
    }

    pub fn is_clean(&self) -> bool {
        self.drifted().is_empty()
    }

    /// Every fix the drifted fields call for, deduplicated, cheapest first.
    pub fn fixes(&self) -> Vec<Fix> {
        let mut out: Vec<Fix> = Vec::new();
        for (_, verdict, fix) in &self.fields {
            if !matches!(verdict, FieldVerdict::Drifted { .. }) {
                continue;
            }
            let fix = fix.unwrap_or(Fix::NewCluster);
            if !out.contains(&fix) {
                out.push(fix);
            }
        }
        out.sort_by_key(|f| match f {
            Fix::AddWorkers(_) | Fix::AddServers(_) => 0,
            Fix::RebuildOnly => 0,
            Fix::ReplaceLoadBalancer => 1,
            Fix::ReplaceNode => 2,
            Fix::NewCluster => 3,
        });
        out
    }

    /// Workers to add, when that is the only thing standing between the
    /// cluster and the declaration.
    pub fn workers_to_add(&self) -> Option<u32> {
        match self.fixes().as_slice() {
            [Fix::AddWorkers(n)] => Some(*n),
            _ => None,
        }
    }

    /// Whether every drifted field can be satisfied without a new cluster.
    pub fn is_convergeable_in_place(&self) -> bool {
        !self.is_clean() && self.fixes().iter().all(|f| f.is_in_place())
    }

    /// Fields that only a different cluster can satisfy.
    pub fn needing_recreate(&self) -> Vec<&'static str> {
        self.fields
            .iter()
            .filter(|(_, v, fix)| {
                matches!(v, FieldVerdict::Drifted { .. })
                    && matches!(fix, Some(Fix::NewCluster) | None)
            })
            .map(|(option, _, _)| *option)
            .collect()
    }
}

fn verdict_of<T: PartialEq + std::fmt::Display>(declared: &T, recorded: &T) -> FieldVerdict {
    if declared == recorded {
        FieldVerdict::Matches
    } else {
        FieldVerdict::Drifted {
            declared: declared.to_string(),
            actual: recorded.to_string(),
        }
    }
}

fn compare_with<T: PartialEq + std::fmt::Display>(
    option: &'static str,
    declared: &T,
    recorded: &T,
    fix: Fix,
) -> (&'static str, FieldVerdict, Option<Fix>) {
    (option, verdict_of(declared, recorded), Some(fix))
}

/// A field whose only remedy is a different cluster.
fn compare<T: PartialEq + std::fmt::Display>(
    option: &'static str,
    declared: &T,
    recorded: &T,
) -> (&'static str, FieldVerdict, Option<Fix>) {
    compare_with(option, declared, recorded, Fix::NewCluster)
}

/// A field baked into the node container's arguments or mounts. Replacing the
/// container against its existing state volume satisfies it.
fn compare_node<T: PartialEq + std::fmt::Display>(
    option: &'static str,
    declared: &T,
    recorded: &T,
) -> (&'static str, FieldVerdict, Option<Fix>) {
    compare_with(option, declared, recorded, Fix::ReplaceNode)
}

fn compare_counts(
    option: &'static str,
    declared: u32,
    recorded: u32,
    grow: fn(u32) -> Fix,
) -> (&'static str, FieldVerdict, Option<Fix>) {
    // Growing is additive and interrupts nothing. Shrinking is not: k3d
    // deletes a node without draining it.
    let fix = if declared > recorded {
        grow(declared - recorded)
    } else {
        Fix::NewCluster
    };
    (option, verdict_of(&declared, &recorded), Some(fix))
}

fn show_opt(v: &Option<String>) -> String {
    v.clone().unwrap_or_else(|| "(unset)".to_string())
}

fn show_list(v: &[String]) -> String {
    if v.is_empty() {
        "(none)".to_string()
    } else {
        format!("[{}]", v.join(", "))
    }
}

/// What changed between the shape a cluster was built from and the one the
/// lab declares now.
pub fn compare_shapes(declared: &ClusterShape, recorded: &ClusterShape) -> DriftReport {
    // Every provisioner builds from these. The k3d block below is compared
    // only for a k3d cluster, because those options describe how k3d builds a
    // cluster and mean nothing to Talos or a cloud provider: reporting them
    // would name an option the operator did not set and cannot act on.
    let mut fields = vec![
        compare(
            "cluster.provisioner",
            &declared.provisioner,
            &recorded.provisioner,
        ),
        compare_counts(
            "cluster.kubernetes.controlPlanes",
            declared.control_planes,
            recorded.control_planes,
            Fix::AddServers,
        ),
        compare_counts(
            "cluster.kubernetes.workers",
            declared.workers,
            recorded.workers,
            Fix::AddWorkers,
        ),
        compare(
            "cluster.kubernetes.distribution",
            &declared.distribution,
            &recorded.distribution,
        ),
        compare_with(
            "cluster.kubernetes.version",
            &declared.version,
            &recorded.version,
            Fix::RebuildOnly,
        ),
        compare(
            "cluster.network.podSubnet",
            &declared.pod_subnet,
            &recorded.pod_subnet,
        ),
        compare(
            "cluster.network.serviceSubnet",
            &declared.service_subnet,
            &recorded.service_subnet,
        ),
    ];

    if declared.provisioner == "k3d" {
        fields.extend(k3d_fields(declared, recorded));
    }

    DriftReport { fields }
}

fn k3d_fields(
    declared: &ClusterShape,
    recorded: &ClusterShape,
) -> Vec<(&'static str, FieldVerdict, Option<Fix>)> {
    vec![
        compare_node(
            "provisioner.k3d.image",
            &show_opt(&declared.image),
            &show_opt(&recorded.image),
        ),
        compare(
            "provisioner.k3d.network",
            &show_opt(&declared.network),
            &show_opt(&recorded.network),
        ),
        compare_node(
            "provisioner.k3d.noTraefik",
            &declared.no_traefik,
            &recorded.no_traefik,
        ),
        compare_node(
            "provisioner.k3d.noServiceLB",
            &declared.no_service_lb,
            &recorded.no_service_lb,
        ),
        compare_node(
            "provisioner.k3d.noFlannel",
            &declared.no_flannel,
            &recorded.no_flannel,
        ),
        compare_node(
            "provisioner.k3d.noLocalStorage",
            &declared.no_local_storage,
            &recorded.no_local_storage,
        ),
        compare_with(
            "provisioner.k3d.ports",
            &show_list(&declared.ports),
            &show_list(&recorded.ports),
            Fix::ReplaceLoadBalancer,
        ),
        compare_node(
            "provisioner.k3d.extraApiServerArgs",
            &show_list(&declared.extra_api_server_args),
            &show_list(&recorded.extra_api_server_args),
        ),
        compare_node(
            "provisioner.k3d.extraVolumes",
            &show_list(&declared.extra_volumes),
            &show_list(&recorded.extra_volumes),
        ),
        compare_node(
            "provisioner.k3d.autoDeployManifests",
            &show_list(&declared.auto_deploy_manifests),
            &show_list(&recorded.auto_deploy_manifests),
        ),
    ]
}

pub fn describe(cluster: &str, report: &DriftReport) -> String {
    let mut out =
        format!("cluster '{cluster}' exists but no longer matches what the lab declares:\n");
    for (option, declared, actual) in report.drifted() {
        out.push_str(&format!(
            "  - {option}: declared {declared}, built with {actual}\n"
        ));
    }
    out.push_str("\nWhat each of those would take:\n");
    for fix in report.fixes() {
        out.push_str(&format!("  - {}\n", fix.cost()));
    }
    out.push_str(
        "\nThe pod and service CIDRs are written into the datastore when the\n\
         cluster is first initialised, and the distribution is a different thing\n\
         entirely, so neither can be changed on a cluster that exists. Everything\n\
         else `lab up` converges in place.\n\n\
         Build a new one, losing what is on this one:\n  \
         cata lab up --recreate <cluster>\n\
         If the cluster is right and the declaration is wrong, change the options\n\
         above instead.",
    );
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    type Mutate = fn(&mut ClusterShape);

    fn shape() -> ClusterShape {
        ClusterShape {
            schema_version: SCHEMA_VERSION,
            provisioner: "k3d".into(),
            control_planes: 1,
            workers: 2,
            distribution: "k3s".into(),
            version: "v1.31.0".into(),
            pod_subnet: "10.42.0.0/16".into(),
            service_subnet: "10.43.0.0/16".into(),
            image: Some("rancher/k3s:v1.31.0-k3s1".into()),
            network: Some("platform".into()),
            no_traefik: true,
            no_service_lb: false,
            no_flannel: false,
            no_local_storage: false,
            ports: vec!["8080:80@loadbalancer".into()],
            extra_api_server_args: vec!["--oidc-issuer-url=https://id.test".into()],
            extra_volumes: vec!["/host:/container".into()],
            auto_deploy_manifests: vec!["coredns-lab-dns".into()],
        }
    }

    #[test]
    fn an_unchanged_declaration_reports_nothing() {
        let report = compare_shapes(&shape(), &shape());
        assert!(report.is_clean());
        assert_eq!(report.drifted(), vec![]);
    }

    // Every one of these was invisible before: the old check compared worker
    // count and the k3s image tag, and nothing else.
    #[test]
    fn every_field_the_old_check_ignored_is_now_seen() {
        let cases: Vec<(&str, Mutate)> = vec![
            ("cluster.kubernetes.controlPlanes", |s| s.control_planes = 3),
            ("cluster.network.podSubnet", |s| {
                s.pod_subnet = "10.44.0.0/16".into()
            }),
            ("cluster.network.serviceSubnet", |s| {
                s.service_subnet = "10.45.0.0/16".into()
            }),
            ("provisioner.k3d.network", |s| {
                s.network = Some("other".into())
            }),
            ("provisioner.k3d.noTraefik", |s| s.no_traefik = false),
            ("provisioner.k3d.noServiceLB", |s| s.no_service_lb = true),
            ("provisioner.k3d.noFlannel", |s| s.no_flannel = true),
            ("provisioner.k3d.noLocalStorage", |s| {
                s.no_local_storage = true
            }),
            ("provisioner.k3d.ports", |s| {
                s.ports = vec!["9090:80@loadbalancer".into()]
            }),
            ("provisioner.k3d.extraApiServerArgs", |s| {
                s.extra_api_server_args = vec![]
            }),
            ("provisioner.k3d.extraVolumes", |s| s.extra_volumes = vec![]),
            ("provisioner.k3d.autoDeployManifests", |s| {
                s.auto_deploy_manifests = vec![]
            }),
        ];

        for (option, mutate) in cases {
            let mut declared = shape();
            mutate(&mut declared);
            let report = compare_shapes(&declared, &shape());
            let drifted: Vec<&str> = report.drifted().iter().map(|(o, _, _)| *o).collect();
            assert_eq!(drifted, vec![option], "changing {option} was not reported");
        }
    }

    #[test]
    fn the_two_fields_the_old_check_did_see_are_still_seen() {
        for (option, mutate) in [
            (
                "cluster.kubernetes.workers",
                (|s: &mut ClusterShape| s.workers = 5) as fn(&mut ClusterShape),
            ),
            ("provisioner.k3d.image", |s: &mut ClusterShape| {
                s.image = Some("rancher/k3s:v1.30.0-k3s1".into())
            }),
        ] {
            let mut declared = shape();
            mutate(&mut declared);
            let drifted: Vec<&str> = compare_shapes(&declared, &shape())
                .drifted()
                .iter()
                .map(|(o, _, _)| *o)
                .collect();
            assert_eq!(drifted, vec![option]);
        }
    }

    #[test]
    fn several_changes_are_all_reported_not_just_the_first() {
        let mut declared = shape();
        declared.workers = 4;
        declared.no_flannel = true;
        declared.ports = vec![];

        let drifted: Vec<&str> = compare_shapes(&declared, &shape())
            .drifted()
            .iter()
            .map(|(o, _, _)| *o)
            .collect();
        assert_eq!(
            drifted,
            vec![
                "cluster.kubernetes.workers",
                "provisioner.k3d.noFlannel",
                "provisioner.k3d.ports",
            ]
        );
    }

    #[test]
    fn the_message_names_the_option_and_both_values() {
        let mut declared = shape();
        declared.pod_subnet = "10.44.0.0/16".into();

        let message = describe("core", &compare_shapes(&declared, &shape()));
        assert!(message.contains("cluster.network.podSubnet"), "{message}");
        assert!(message.contains("10.44.0.0/16"), "{message}");
        assert!(message.contains("10.42.0.0/16"), "{message}");
        assert!(message.contains("--recreate"), "{message}");
    }

    // `cluster.kubernetes.version` selects which generated schemas the
    // manifests are typed against. The node image is what decides the
    // Kubernetes a cluster runs, and conflating the two made a replacement run
    // with an unchanged image and then record that the version had moved.
    #[test]
    fn the_schema_version_is_not_the_running_kubernetes() {
        let mut declared = shape();
        declared.version = "1.32".into();
        let report = compare_shapes(&declared, &shape());
        assert_eq!(report.fixes(), vec![Fix::RebuildOnly]);
        assert!(report.is_convergeable_in_place());
    }

    // The message used to assert that reshaping any k3d cluster loses
    // everything on it. That is only true of the two datastore-baked fields,
    // and believing it of the rest is what kept version bumps out of `up`.
    #[test]
    fn the_message_says_what_the_specific_change_costs() {
        let mut declared = shape();
        declared.image = Some("rancher/k3s:v1.32.5-k3s1".into());
        let message = describe("core", &compare_shapes(&declared, &shape()));
        assert!(message.contains("keeping its data"), "{message}");
        assert!(
            !message.contains("everything on this one is lost"),
            "a node replacement must not be described as total loss: {message}"
        );
    }

    #[test]
    fn a_record_round_trips_through_json() {
        let json = serde_json::to_string(&shape()).unwrap();
        let back: ClusterShape = serde_json::from_str(&json).unwrap();
        assert_eq!(back, shape());
    }

    #[test]
    fn more_workers_than_the_cluster_has_is_fixed_by_adding_them() {
        let mut declared = shape();
        declared.workers = 5;
        let report = compare_shapes(&declared, &shape());
        assert_eq!(report.workers_to_add(), Some(3));
        assert_eq!(report.needing_recreate(), Vec::<&str>::new());
    }

    // k3d deletes a node without draining it, so anything scheduled there
    // goes with it. Shrinking is not something to do behind the operator.
    #[test]
    fn fewer_workers_is_not_reconciled_in_place() {
        let mut declared = shape();
        declared.workers = 1;
        let report = compare_shapes(&declared, &shape());
        assert_eq!(report.workers_to_add(), None);
        assert_eq!(
            report.needing_recreate(),
            vec!["cluster.kubernetes.workers"]
        );
    }

    // Two changes at once means the cheap one is no longer the whole answer,
    // so `workers_to_add` stops being the shortcut. Both are still in place.
    #[test]
    fn adding_workers_alongside_a_port_change_is_two_fixes_not_a_recreate() {
        let mut declared = shape();
        declared.workers = 5;
        declared.ports = vec!["9090:80@loadbalancer".into()];
        let report = compare_shapes(&declared, &shape());
        assert_eq!(report.workers_to_add(), None);
        assert_eq!(report.needing_recreate(), Vec::<&str>::new());
        assert!(report.is_convergeable_in_place());
        assert_eq!(
            report.fixes(),
            vec![Fix::AddWorkers(3), Fix::ReplaceLoadBalancer]
        );
    }

    // Verified against a live cluster: replacing the node container against
    // its existing state volume kept the workloads, the PVC binding and the
    // data, and moved the version. None of these needs a new cluster.
    #[test]
    fn a_node_level_change_is_satisfied_by_replacing_the_node() {
        for mutate in [
            (|s: &mut ClusterShape| s.no_flannel = true) as Mutate,
            |s: &mut ClusterShape| s.extra_volumes = vec![],
            |s: &mut ClusterShape| s.image = Some("rancher/k3s:v1.30.0-k3s1".into()),
            |s: &mut ClusterShape| s.extra_api_server_args = vec![],
        ] {
            let mut declared = shape();
            mutate(&mut declared);
            let report = compare_shapes(&declared, &shape());
            assert_eq!(report.fixes(), vec![Fix::ReplaceNode]);
            assert!(report.is_convergeable_in_place());
            assert_eq!(report.needing_recreate(), Vec::<&str>::new());
        }
    }

    // The CIDRs are written into the datastore at first init and the
    // distribution is a different thing entirely, so these two are the only
    // fields a running cluster cannot be talked out of.
    #[test]
    fn only_the_datastore_baked_fields_need_a_new_cluster() {
        for (mutate, option) in [
            (
                (|s: &mut ClusterShape| s.pod_subnet = "10.44.0.0/16".into()) as Mutate,
                "cluster.network.podSubnet",
            ),
            (
                |s: &mut ClusterShape| s.service_subnet = "10.45.0.0/16".into(),
                "cluster.network.serviceSubnet",
            ),
            (
                |s: &mut ClusterShape| s.distribution = "k8s".into(),
                "cluster.kubernetes.distribution",
            ),
        ] {
            let mut declared = shape();
            mutate(&mut declared);
            let report = compare_shapes(&declared, &shape());
            assert_eq!(report.needing_recreate(), vec![option]);
            assert!(!report.is_convergeable_in_place());
        }
    }

    #[test]
    fn growing_the_control_plane_adds_servers() {
        let mut declared = shape();
        declared.control_planes = 3;
        let report = compare_shapes(&declared, &shape());
        assert_eq!(report.fixes(), vec![Fix::AddServers(2)]);
        assert!(report.is_convergeable_in_place());
    }

    fn talos_shape() -> ClusterShape {
        ClusterShape {
            provisioner: "talos".into(),
            ..shape()
        }
    }

    // Talos had no drift check at all: an existing cluster short-circuited on
    // "already running", while `cluster_create` reads controlPlanes and
    // workers. Raising either changed the declaration and nothing else.
    #[test]
    fn a_talos_cluster_still_notices_a_node_count_change() {
        let mut declared = talos_shape();
        declared.control_planes = 3;
        let report = compare_shapes(&declared, &talos_shape());
        assert!(!report.is_clean(), "the change must be noticed at all");
        assert_eq!(report.fixes(), vec![Fix::AddServers(2)]);
    }

    // The k3d block describes how k3d builds a cluster. Reporting it for a
    // Talos cluster would name an option the operator did not set and cannot
    // act on.
    #[test]
    fn k3d_options_are_not_reported_against_a_cluster_k3d_did_not_build() {
        let mut declared = talos_shape();
        declared.no_flannel = true;
        declared.ports = vec!["9090:90@loadbalancer".into()];
        let report = compare_shapes(&declared, &talos_shape());
        assert!(report.is_clean(), "{:?}", report.drifted());
    }

    #[test]
    fn the_same_k3d_options_are_still_reported_for_a_k3d_cluster() {
        let mut declared = shape();
        declared.no_flannel = true;
        let report = compare_shapes(&declared, &shape());
        assert_eq!(
            report
                .drifted()
                .iter()
                .map(|(o, _, _)| *o)
                .collect::<Vec<_>>(),
            vec!["provisioner.k3d.noFlannel"]
        );
    }

    // Swapping the provisioner is not a change to a cluster, it is a
    // different cluster, so it can only be satisfied by building one.
    #[test]
    fn changing_the_provisioner_needs_a_new_cluster() {
        let report = compare_shapes(&shape(), &talos_shape());
        assert!(report.needing_recreate().contains(&"cluster.provisioner"));
        assert_eq!(report.workers_to_add(), None);
    }

    // A record is what drift is compared against, so a field it carries that
    // the cluster never saw is worse than a field it omits.
    #[test]
    fn a_non_k3d_shape_records_no_k3d_options() {
        let mut json = crate::domain::cluster::tests::cluster_json();
        json["provisioner"] = serde_json::json!("talos");
        json["provisionerConfig"]["k3d"]["noTraefik"] = serde_json::json!(true);
        json["provisionerConfig"]["k3d"]["image"] = serde_json::json!("rancher/k3s:v1.31.4-k3s1");
        json["provisionerConfig"]["k3d"]["extraApiServerArgs"] =
            serde_json::json!(["--oidc-issuer-url=x"]);
        let spec = ClusterSpec::from_value(json).expect("fixture parses");

        let recorded = ClusterShape::of(&spec);
        assert_eq!(recorded.image, None);
        assert!(!recorded.no_traefik);
        assert_eq!(recorded.extra_api_server_args, Vec::<String>::new());
    }

    #[test]
    fn a_k3d_shape_still_records_them() {
        let mut json = crate::domain::cluster::tests::cluster_json();
        json["provisioner"] = serde_json::json!("k3d");
        json["provisionerConfig"]["k3d"]["noTraefik"] = serde_json::json!(true);
        json["provisionerConfig"]["k3d"]["image"] = serde_json::json!("rancher/k3s:v1.31.4-k3s1");
        let spec = ClusterSpec::from_value(json).expect("fixture parses");

        let recorded = ClusterShape::of(&spec);
        assert_eq!(recorded.image.as_deref(), Some("rancher/k3s:v1.31.4-k3s1"));
        assert!(recorded.no_traefik);
    }

    #[test]
    fn a_matching_cluster_needs_neither() {
        let report = compare_shapes(&shape(), &shape());
        assert_eq!(report.workers_to_add(), None);
        assert_eq!(report.needing_recreate(), Vec::<&str>::new());
    }
}

//! What is actually running on this machine, worked out from local evidence.
//!
//! `lab list` used to answer only "what does this flake define". A lab left
//! behind by a failed `lab up`, or one the flake no longer defines, was
//! invisible: the machine could not be asked what it was running.
//!
//! Everything here is a pure function over gathered facts, so the reasoning is
//! testable without docker. `io::host_inventory` collects the facts and makes
//! no decisions.

use std::collections::{BTreeMap, BTreeSet};

use super::lab_record::LabRecord;
use super::provenance;

/// The host service names a lab's containers end in. Closed set, and the strip
/// is right-anchored so a lab name containing `-` survives it.
const SERVICE_SUFFIXES: [&str; 4] = ["ingress", "dns", "registry", "router"];

const CONTAINER_PREFIX: &str = "catallaxy-";

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ContainerFact {
    pub name: String,
    pub running: bool,
    pub labels: BTreeMap<String, String>,
    pub published: Vec<u16>,
}

/// Raw observations. No interpretation.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct HostFacts {
    /// False means the answers below are unknown, not empty.
    pub docker_reachable: bool,
    pub containers: Vec<ContainerFact>,
    pub networks: Vec<String>,
    pub k3d_clusters: Vec<String>,
    pub records: Vec<LabRecord>,
}

/// How a thing was tied to a lab, weakest last.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Attribution {
    /// The container carries `catallaxy.io/lab`.
    Labelled,
    /// The container name has the shape a lab's host service has.
    NameShaped,
    /// A lab record names it.
    Recorded,
}

/// Which flake a lab's containers came from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Origin {
    Unknown,
    One(String),
    /// Two of one lab's containers disagree, so it has been run from more than
    /// one checkout. Both are shown and neither is chosen.
    Conflicting(Vec<String>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunningLab {
    pub name: String,
    pub origin: Origin,
    pub containers: Vec<String>,
    pub k3d_clusters: Vec<String>,
    pub network: Option<String>,
    pub has_record: bool,
    pub attributions: BTreeSet<Attribution>,
}

/// Something on this machine that no lab claims.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Orphan {
    /// A catallaxy container whose lab cannot be worked out. `catallaxy-router`
    /// predates per-lab naming and lands here.
    UnattributedContainer { name: String, published: Vec<u16> },
    /// A k3d cluster no record claims. Its name cannot be inverted to a lab.
    UnknownK3dCluster { name: String },
    /// A record with nothing of its live. Says a lab was here, not that it is.
    StaleRecordOnly { lab: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Inventory {
    pub docker_reachable: bool,
    pub labs: Vec<RunningLab>,
    pub orphans: Vec<Orphan>,
}

/// The lab a container name implies, if it has the shape of one.
///
/// Right-anchored on purpose: `catallaxy-home-lab-ingress` is lab `home-lab`,
/// not lab `home`. `catallaxy-router` has no lab segment and yields nothing.
pub fn lab_from_container_name(name: &str) -> Option<&str> {
    let rest = name.strip_prefix(CONTAINER_PREFIX)?;
    SERVICE_SUFFIXES.iter().find_map(|suffix| {
        rest.strip_suffix(suffix)
            .and_then(|head| head.strip_suffix('-'))
            .filter(|lab| !lab.is_empty())
    })
}

fn merge_origin(current: Origin, seen: &str) -> Origin {
    match current {
        Origin::Unknown => Origin::One(seen.to_string()),
        Origin::One(existing) if existing == seen => Origin::One(existing),
        Origin::One(existing) => Origin::Conflicting(vec![existing, seen.to_string()]),
        Origin::Conflicting(mut all) => {
            if !all.iter().any(|f| f == seen) {
                all.push(seen.to_string());
            }
            Origin::Conflicting(all)
        }
    }
}

struct Building {
    origin: Origin,
    containers: Vec<String>,
    k3d_clusters: Vec<String>,
    has_record: bool,
    attributions: BTreeSet<Attribution>,
}

impl Default for Building {
    fn default() -> Self {
        Building {
            origin: Origin::Unknown,
            containers: Vec::new(),
            k3d_clusters: Vec::new(),
            has_record: false,
            attributions: BTreeSet::new(),
        }
    }
}

pub fn correlate(facts: &HostFacts) -> Inventory {
    let mut labs: BTreeMap<String, Building> = BTreeMap::new();
    let mut orphans = Vec::new();

    for container in &facts.containers {
        let attributed = match provenance::lab_of(&container.labels) {
            Some(lab) => Some((lab.to_string(), Attribution::Labelled)),
            None => lab_from_container_name(&container.name)
                .map(|lab| (lab.to_string(), Attribution::NameShaped)),
        };

        let Some((lab, how)) = attributed else {
            if container.name.starts_with(CONTAINER_PREFIX) {
                orphans.push(Orphan::UnattributedContainer {
                    name: container.name.clone(),
                    published: container.published.clone(),
                });
            }
            continue;
        };

        let entry = labs.entry(lab).or_default();
        entry.containers.push(container.name.clone());
        entry.attributions.insert(how);
        if let Some(flake) = provenance::flake_of(&container.labels) {
            entry.origin =
                merge_origin(std::mem::replace(&mut entry.origin, Origin::Unknown), flake);
        }
    }

    // A cluster is tied to a lab only through a record. contextPrefix is lossy,
    // so inverting the name would be a guess, and a wrong guess deletes someone
    // else's cluster.
    let mut claimed_clusters: BTreeMap<&str, &str> = BTreeMap::new();
    for record in &facts.records {
        for k3d in record.k3d_cluster_names() {
            claimed_clusters.insert(k3d, record.lab.as_str());
        }
    }

    for cluster in &facts.k3d_clusters {
        match claimed_clusters.get(cluster.as_str()) {
            Some(lab) => {
                let entry = labs.entry((*lab).to_string()).or_default();
                entry.k3d_clusters.push(cluster.clone());
                entry.attributions.insert(Attribution::Recorded);
            }
            None => orphans.push(Orphan::UnknownK3dCluster {
                name: cluster.clone(),
            }),
        }
    }

    for record in &facts.records {
        match labs.get_mut(&record.lab) {
            Some(entry) => {
                entry.has_record = true;
                entry.attributions.insert(Attribution::Recorded);
                if !record.flake.is_empty() {
                    entry.origin = merge_origin(
                        std::mem::replace(&mut entry.origin, Origin::Unknown),
                        &record.flake,
                    );
                }
            }
            None => orphans.push(Orphan::StaleRecordOnly {
                lab: record.lab.clone(),
            }),
        }
    }

    let networks: BTreeSet<&str> = facts.networks.iter().map(String::as_str).collect();

    let labs = labs
        .into_iter()
        .map(|(name, b)| RunningLab {
            network: networks.contains(name.as_str()).then(|| name.clone()),
            name,
            origin: b.origin,
            containers: b.containers,
            k3d_clusters: b.k3d_clusters,
            has_record: b.has_record,
            attributions: b.attributions,
        })
        .collect();

    Inventory {
        docker_reachable: facts.docker_reachable,
        labs,
        orphans,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::lab_record::{ClusterRecord, LabRecord, SCHEMA_VERSION};

    fn labelled(name: &str, lab: &str, flake: &str) -> ContainerFact {
        ContainerFact {
            name: name.into(),
            running: true,
            labels: crate::domain::provenance::Provenance::new(lab, flake)
                .labels("proxy")
                .into_iter()
                .collect(),
            published: vec![],
        }
    }

    fn unlabelled(name: &str) -> ContainerFact {
        ContainerFact {
            name: name.into(),
            running: true,
            ..Default::default()
        }
    }

    fn record_for(lab: &str, k3d: &str) -> LabRecord {
        LabRecord {
            schema_version: SCHEMA_VERSION,
            lab: lab.into(),
            flake: "/src#l".into(),
            network: lab.into(),
            docker_subnet: "172.20.0.0/16".into(),
            dns_zone: None,
            services: vec![],
            clusters: vec![ClusterRecord {
                cluster: "app".into(),
                provisioner: "k3d".into(),
                k3d_cluster: Some(k3d.into()),
                kube_context: format!("k3d-{k3d}"),
            }],
        }
    }

    #[test]
    fn a_lab_name_containing_a_dash_survives_the_suffix_strip() {
        assert_eq!(
            lab_from_container_name("catallaxy-home-lab-ingress"),
            Some("home-lab")
        );
        assert_eq!(
            lab_from_container_name("catallaxy-minimal.local-dns"),
            Some("minimal.local")
        );
    }

    #[test]
    fn the_legacy_router_names_no_lab() {
        assert_eq!(lab_from_container_name("catallaxy-router"), None);
    }

    #[test]
    fn something_that_is_not_ours_names_no_lab() {
        assert_eq!(lab_from_container_name("postgres"), None);
        assert_eq!(lab_from_container_name("catallaxy-lab-postgres"), None);
    }

    #[test]
    fn an_unlabelled_catallaxy_container_is_attributed_by_its_name() {
        let inv = correlate(&HostFacts {
            docker_reachable: true,
            containers: vec![unlabelled("catallaxy-old-demo-ingress")],
            ..Default::default()
        });
        assert_eq!(inv.labs.len(), 1);
        assert_eq!(inv.labs[0].name, "old-demo");
        assert!(inv.labs[0].attributions.contains(&Attribution::NameShaped));
    }

    #[test]
    fn a_label_is_believed_over_the_name() {
        let mut c = labelled("catallaxy-wrong-name-ingress", "the-real-lab", "/src#x");
        c.published = vec![80];
        let inv = correlate(&HostFacts {
            docker_reachable: true,
            containers: vec![c],
            ..Default::default()
        });
        assert_eq!(inv.labs[0].name, "the-real-lab");
        assert!(inv.labs[0].attributions.contains(&Attribution::Labelled));
    }

    #[test]
    fn a_lab_with_only_host_services_is_still_running_here() {
        let inv = correlate(&HostFacts {
            docker_reachable: true,
            containers: vec![labelled("catallaxy-l-ingress", "l", "/src#l")],
            ..Default::default()
        });
        assert_eq!(inv.labs.len(), 1);
        assert!(inv.labs[0].k3d_clusters.is_empty());
    }

    #[test]
    fn a_lab_with_only_a_cluster_is_still_running_here() {
        let inv = correlate(&HostFacts {
            docker_reachable: true,
            k3d_clusters: vec!["l-app".into()],
            records: vec![record_for("l", "l-app")],
            ..Default::default()
        });
        assert_eq!(inv.labs.len(), 1);
        assert_eq!(inv.labs[0].k3d_clusters, vec!["l-app"]);
        assert!(inv.labs[0].containers.is_empty());
        assert!(inv.orphans.is_empty());
    }

    #[test]
    fn a_k3d_cluster_with_no_record_is_an_orphan_not_a_guessed_lab() {
        let inv = correlate(&HostFacts {
            docker_reachable: true,
            k3d_clusters: vec!["home-lab-core".into()],
            ..Default::default()
        });
        assert!(inv.labs.is_empty(), "the name must not be inverted");
        assert_eq!(
            inv.orphans,
            vec![Orphan::UnknownK3dCluster {
                name: "home-lab-core".into()
            }]
        );
    }

    #[test]
    fn a_record_with_nothing_live_is_not_a_running_lab() {
        let inv = correlate(&HostFacts {
            docker_reachable: true,
            records: vec![record_for("gone", "gone-app")],
            ..Default::default()
        });
        assert!(inv.labs.is_empty());
        assert_eq!(
            inv.orphans,
            vec![Orphan::StaleRecordOnly { lab: "gone".into() }]
        );
    }

    #[test]
    fn two_flake_values_on_one_lab_are_reported_as_conflicting_not_resolved() {
        let inv = correlate(&HostFacts {
            docker_reachable: true,
            containers: vec![
                labelled("catallaxy-l-ingress", "l", "/src/a#l"),
                labelled("catallaxy-l-dns", "l", "/src/b#l"),
            ],
            ..Default::default()
        });
        match &inv.labs[0].origin {
            Origin::Conflicting(all) => {
                assert!(all.contains(&"/src/a#l".to_string()));
                assert!(all.contains(&"/src/b#l".to_string()));
            }
            other => panic!("two checkouts must not be resolved to one: {other:?}"),
        }
    }

    #[test]
    fn one_flake_across_a_labs_containers_is_not_a_conflict() {
        let inv = correlate(&HostFacts {
            docker_reachable: true,
            containers: vec![
                labelled("catallaxy-l-ingress", "l", "/src#l"),
                labelled("catallaxy-l-dns", "l", "/src#l"),
            ],
            ..Default::default()
        });
        assert_eq!(inv.labs[0].origin, Origin::One("/src#l".into()));
    }

    #[test]
    fn the_legacy_router_is_reported_as_claimed_by_nobody() {
        let inv = correlate(&HostFacts {
            docker_reachable: true,
            containers: vec![unlabelled("catallaxy-router")],
            ..Default::default()
        });
        assert!(inv.labs.is_empty());
        assert_eq!(
            inv.orphans,
            vec![Orphan::UnattributedContainer {
                name: "catallaxy-router".into(),
                published: vec![]
            }]
        );
    }

    #[test]
    fn a_network_alone_never_invents_a_lab() {
        let inv = correlate(&HostFacts {
            docker_reachable: true,
            networks: vec!["someone-elses-network".into()],
            ..Default::default()
        });
        assert!(inv.labs.is_empty());
        assert!(inv.orphans.is_empty());
    }

    #[test]
    fn a_network_is_joined_to_a_lab_that_other_evidence_already_found() {
        let inv = correlate(&HostFacts {
            docker_reachable: true,
            containers: vec![labelled("catallaxy-l-ingress", "l", "/src#l")],
            networks: vec!["l".into()],
            ..Default::default()
        });
        assert_eq!(inv.labs[0].network.as_deref(), Some("l"));
    }

    #[test]
    fn an_unreachable_docker_is_not_an_empty_inventory() {
        let inv = correlate(&HostFacts::default());
        assert!(
            !inv.docker_reachable,
            "callers must be able to say 'unknown' rather than 'nothing here'"
        );
    }

    #[test]
    fn a_container_that_is_not_ours_is_ignored_entirely() {
        let inv = correlate(&HostFacts {
            docker_reachable: true,
            containers: vec![unlabelled("postgres")],
            ..Default::default()
        });
        assert!(inv.labs.is_empty());
        assert!(inv.orphans.is_empty());
    }
}

/// One thing to remove, in the order it must happen.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CleanupAction {
    DestroyK3dCluster(String),
    RemoveContainer(String),
    RemoveNetwork(String),
    /// Kubeconfig entries for a cluster whose lab-facing name is known.
    CleanKubeconfig(String),
    /// Something only root can remove. Reported, never done.
    ReportOnly {
        what: String,
        remedy: String,
    },
    ForgetState(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CleanupPlan {
    pub lab: Option<String>,
    pub actions: Vec<CleanupAction>,
}

/// What removing a lab means, as data.
///
/// Clusters go before containers because a k3d node sits on the lab's docker
/// network, and the network cannot be removed while anything is attached. The
/// state directory goes last so nothing that reads it has been cut off first.
pub fn plan_cleanup(lab: &RunningLab, record: Option<&LabRecord>, keep_state: bool) -> CleanupPlan {
    let mut actions = Vec::new();

    for cluster in &lab.k3d_clusters {
        actions.push(CleanupAction::DestroyK3dCluster(cluster.clone()));
    }

    for container in &lab.containers {
        actions.push(CleanupAction::RemoveContainer(container.clone()));
    }

    if let Some(network) = &lab.network {
        actions.push(CleanupAction::RemoveNetwork(network.clone()));
    }

    // cleanup_kubeconfig keys on the lab-facing cluster name, which only the
    // record carries. Without one, deleting a context matched by a guess could
    // take out someone else's.
    match record {
        Some(record) => {
            for cluster in &record.clusters {
                actions.push(CleanupAction::CleanKubeconfig(cluster.cluster.clone()));
            }
        }
        None if !lab.k3d_clusters.is_empty() => {
            actions.push(CleanupAction::ReportOnly {
                what: format!("kubeconfig entries for {}", lab.k3d_clusters.join(", ")),
                remedy: "there is no record of this lab's cluster names, so the \
                         entries are left alone rather than matched by a guess. \
                         Remove them with `kubectl config delete-context <name>`"
                    .to_string(),
            });
        }
        None => {}
    }

    actions.push(CleanupAction::ReportOnly {
        what: format!("the host CA at /usr/local/share/ca-certificates/catallaxy-{}.crt", lab.name),
        remedy: format!(
            "it is root-owned, so remove it yourself if this lab is finished with: \
             sudo rm -f /usr/local/share/ca-certificates/catallaxy-{}.crt && sudo update-ca-certificates",
            lab.name
        ),
    });

    if !keep_state {
        actions.push(CleanupAction::ForgetState(lab.name.clone()));
    }

    CleanupPlan {
        lab: Some(lab.name.clone()),
        actions,
    }
}

#[cfg(test)]
mod cleanup_tests {
    use super::*;

    fn lab(containers: &[&str], clusters: &[&str], network: Option<&str>) -> RunningLab {
        RunningLab {
            name: "l".into(),
            origin: Origin::Unknown,
            containers: containers.iter().map(|s| s.to_string()).collect(),
            k3d_clusters: clusters.iter().map(|s| s.to_string()).collect(),
            network: network.map(String::from),
            has_record: false,
            attributions: BTreeSet::new(),
        }
    }

    fn positions(plan: &CleanupPlan) -> Vec<&'static str> {
        plan.actions
            .iter()
            .map(|a| match a {
                CleanupAction::DestroyK3dCluster(_) => "cluster",
                CleanupAction::RemoveContainer(_) => "container",
                CleanupAction::RemoveNetwork(_) => "network",
                CleanupAction::CleanKubeconfig(_) => "kubeconfig",
                CleanupAction::ReportOnly { .. } => "report",
                CleanupAction::ForgetState(_) => "state",
            })
            .collect()
    }

    // A k3d node sits on the lab's network, so the network cannot go first.
    #[test]
    fn the_network_is_removed_after_every_container_and_cluster_on_it() {
        let plan = plan_cleanup(&lab(&["c"], &["k"], Some("n")), None, false);
        let order = positions(&plan);
        let network = order.iter().position(|p| *p == "network").unwrap();
        assert!(order.iter().position(|p| *p == "cluster").unwrap() < network);
        assert!(order.iter().position(|p| *p == "container").unwrap() < network);
    }

    #[test]
    fn a_lab_with_no_record_still_gets_its_containers_removed() {
        let plan = plan_cleanup(&lab(&["catallaxy-l-ingress"], &[], None), None, false);
        assert!(plan.actions.contains(&CleanupAction::RemoveContainer(
            "catallaxy-l-ingress".into()
        )));
    }

    #[test]
    fn a_root_owned_ca_is_reported_and_never_removed() {
        let plan = plan_cleanup(&lab(&[], &[], None), None, false);
        let reported = plan.actions.iter().any(|a| {
            matches!(
                a,
                CleanupAction::ReportOnly { what, .. } if what.contains("host CA")
            )
        });
        assert!(reported, "{:?}", plan.actions);
    }

    // Without a record the lab-facing cluster name is unknown, and matching a
    // context by guess could delete someone else's.
    #[test]
    fn kubeconfig_is_left_alone_when_no_record_names_the_cluster() {
        let plan = plan_cleanup(&lab(&[], &["l-app"], None), None, false);
        assert!(!positions(&plan).contains(&"kubeconfig"));
        assert!(plan.actions.iter().any(|a| matches!(
            a,
            CleanupAction::ReportOnly { what, .. } if what.contains("kubeconfig")
        )));
    }

    #[test]
    fn kubeconfig_is_cleaned_when_a_record_names_the_cluster() {
        let record = LabRecord {
            schema_version: crate::domain::lab_record::SCHEMA_VERSION,
            lab: "l".into(),
            flake: "/src#l".into(),
            network: "l".into(),
            docker_subnet: "172.20.0.0/16".into(),
            dns_zone: None,
            services: vec![],
            clusters: vec![crate::domain::lab_record::ClusterRecord {
                cluster: "app".into(),
                provisioner: "k3d".into(),
                k3d_cluster: Some("l-app".into()),
                kube_context: "k3d-l-app".into(),
            }],
        };
        let plan = plan_cleanup(&lab(&[], &["l-app"], None), Some(&record), false);
        assert!(
            plan.actions
                .contains(&CleanupAction::CleanKubeconfig("app".into()))
        );
    }

    #[test]
    fn the_state_directory_goes_last_and_only_when_asked() {
        let plan = plan_cleanup(&lab(&["c"], &[], None), None, false);
        assert_eq!(positions(&plan).last(), Some(&"state"));

        let kept = plan_cleanup(&lab(&["c"], &[], None), None, true);
        assert!(!positions(&kept).contains(&"state"));
    }

    #[test]
    fn a_lab_with_nothing_live_plans_only_what_is_reported() {
        let plan = plan_cleanup(&lab(&[], &[], None), None, true);
        assert!(
            plan.actions
                .iter()
                .all(|a| matches!(a, CleanupAction::ReportOnly { .. })),
            "{:?}",
            plan.actions
        );
    }
}

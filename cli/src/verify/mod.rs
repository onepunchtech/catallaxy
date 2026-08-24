pub mod checks;

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::domain::LabSpec;
pub use crate::domain::diagnostic::{Diagnostic, Severity};

pub const CHECK_NAMES: [&str; 6] = [
    "clusters",
    "services",
    "rollouts",
    "endpoints",
    "certificates",
    "chainsaw",
];

#[derive(Debug, Clone, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct VerifyConfig {
    #[serde(default)]
    pub checks: BTreeMap<String, DeclaredCheck>,
    #[serde(default)]
    pub endpoints: EndpointPolicy,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeclaredCheck {
    pub description: String,
    pub severity: String,
    pub scope: String,
    pub command: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EndpointPolicy {
    pub enable: bool,
    #[serde(default)]
    pub accept_statuses: Vec<u16>,
}

impl Default for EndpointPolicy {
    fn default() -> Self {
        EndpointPolicy {
            enable: true,
            accept_statuses: Vec::new(),
        }
    }
}

pub use crate::domain::ExposedHost;

pub struct VerifyContext<'a> {
    pub lab_name: &'a str,
    pub lab: &'a LabSpec,
    pub config: &'a VerifyConfig,
    pub package: Option<&'a std::path::Path>,
}

impl VerifyContext<'_> {
    pub fn context_for(&self, cluster: &str) -> Option<&str> {
        self.lab.kube_context(cluster).ok()
    }

    pub fn namespaces_for(&self, cluster: &str) -> &[String] {
        self.lab.namespaces_for(cluster)
    }

    pub fn exposed_hosts(&self) -> Vec<(String, ExposedHost)> {
        let mut out: Vec<(String, ExposedHost)> = self
            .lab
            .clusters
            .iter()
            .flat_map(|(cluster, spec)| {
                spec.exposed_hosts
                    .iter()
                    .map(move |host| (cluster.clone(), host.clone()))
            })
            .collect();
        out.sort_by(|a, b| a.1.host.cmp(&b.1.host));
        out.dedup_by(|a, b| a.1.host == b.1.host);
        out
    }

    pub fn ingress(&self) -> Option<(&'static str, u16)> {
        let published: Vec<(u16, u16)> = self
            .lab
            .services
            .get("proxy")?
            .ports
            .iter()
            .filter_map(|p| published_port(p))
            .collect();

        ingress_endpoint(&published)
    }
}

/// The reachable-from-here publishes, as (host, container) pairs.
///
/// A gateway-bound publish is for pods and containers inside the lab, and
/// verify runs on this machine.
fn published_port(mapping: &str) -> Option<(u16, u16)> {
    let m = crate::domain::port_mapping::PortMapping::parse(mapping)?;
    m.is_host_reachable().then_some((m.host, m.container))
}

pub fn ingress_endpoint(published: &[(u16, u16)]) -> Option<(&'static str, u16)> {
    let on_container_port = |want: u16| published.iter().find(|(_, c)| *c == want).map(|(h, _)| *h);

    on_container_port(443)
        .map(|host| ("https", host))
        .or_else(|| on_container_port(80).map(|host| ("http", host)))
}

pub async fn run(ctx: &VerifyContext<'_>, only: Option<&str>) -> Vec<Diagnostic> {
    let wanted = |name: &str| only.is_none_or(|o| o == name);

    let mut diags = Vec::new();
    if wanted("clusters") {
        diags.extend(checks::clusters::run(ctx));
    }
    if wanted("services") {
        diags.extend(checks::services::run(ctx));
    }
    if wanted("rollouts") {
        diags.extend(checks::rollouts::run(ctx));
    }
    if wanted("endpoints") {
        diags.extend(checks::endpoints::run(ctx).await);
    }
    if wanted("certificates") {
        diags.extend(checks::certificates::run(ctx));
    }
    if wanted("chainsaw")
        && let Some(package) = ctx.package
    {
        diags.extend(checks::chainsaw::run(ctx, package));
    }
    diags
}

#[derive(Debug, Serialize)]
pub struct JsonDiagnostic {
    pub severity: &'static str,
    pub check: &'static str,
    pub cluster: String,
    pub resource: String,
    pub message: String,
}

pub fn as_json(diagnostics: &[Diagnostic]) -> Vec<JsonDiagnostic> {
    diagnostics
        .iter()
        .map(|d| JsonDiagnostic {
            severity: match d.severity {
                Severity::Error => "error",
                Severity::Warning => "warning",
            },
            check: d.check,
            cluster: d.cluster.clone(),
            resource: d.resource.clone(),
            message: d.message.clone(),
        })
        .collect()
}

pub fn diag(
    severity: Severity,
    check: &'static str,
    cluster: &str,
    resource: &str,
    message: String,
) -> Diagnostic {
    Diagnostic {
        severity,
        check,
        cluster: cluster.to_string(),
        file: std::path::PathBuf::new(),
        resource: resource.to_string(),
        message,
    }
}

#[cfg(test)]
mod tests {

    /// The ingress publishes on loopback and on the lab's own gateway, so a
    /// mapping carries an address. Reading the address as the host port made
    /// verify say a working lab published no ingress at all.
    #[test]
    fn the_ingress_port_is_found_whatever_it_is_bound_to() {
        assert_eq!(super::published_port("127.0.0.1:8080:80"), Some((8080, 80)));
        assert_eq!(super::published_port("8080:80"), Some((8080, 80)));
        assert_eq!(
            super::published_port("127.0.0.1:9443:443"),
            Some((9443, 443))
        );
        // The gateway publish is for pods, not for anything running here.
        assert_eq!(super::published_port("172.20.0.1:80:80"), None);
    }
    use super::*;

    use serde_json::{Value, json};

    fn merge(base: &mut Value, over: Value) {
        match (base, over) {
            (Value::Object(b), Value::Object(o)) => {
                for (k, v) in o {
                    merge(b.entry(k).or_insert(Value::Null), v);
                }
            }
            (b, o) => *b = o,
        }
    }

    fn base_lab() -> Value {
        json!({
            "labName": "l",
            "environment": "development",
            "clusterNames": [],
            "clusters": {},
            "labNamespaces": {},
            "network": { "name": "l", "dockerSubnet": "172.20.0.0/16" },
            "dnsInfo": null,
            "registryPort": null,
            "registryUpstreams": [],
            "labOwnedRegistries": [],
            "opsToolPath": null,
            "cd": { "strategy": "kapp", "bootstrap": "kubectl-ssa", "git": {} },
            "secrets": { "envFile": null, "stores": {}, "managed": {}, "hostProjections": [] },
            "deploymentPlan": [],
            "teardownPlan": [],
            "runtimeContexts": {},
            "services": {},
            "selfContained": { "eligible": true, "envFile": null, "reasons": [] },
            "destroy": { "rescueHints": {} },
            "verify": {},
        })
    }

    fn base_cluster(name: &str) -> Value {
        json!({
            "name": name,
            "labName": "l",
            "provisioner": "k3d",
            "provider": "docker",
            "kubeContext": format!("k3d-{name}"),
            "kubernetes": { "distribution": "k3s", "version": "1.31", "controlPlanes": 1, "workers": 0 },
            "network": { "podSubnet": "10.244.0.0/16", "serviceSubnet": "10.96.0.0/12" },
            "deploy": { "strategy": "kapp" },
            "lifecycle": { "preProvision": [] },
            "provisionerConfig": {
                "k3d": { "clusterName": name, "image": null, "network": null,
                         "noTraefik": true, "noServiceLB": false, "noFlannel": false, "noLocalStorage": false,
                         "ports": [], "extraApiServerArgs": [], "extraVolumes": [],
                         "autoDeployManifests": [] },
                "docker": { "clusterName": name, "waitTimeout": "10m",
                            "colima": { "enable": true, "profile": "catallaxy", "cpu": 4, "disk": 60, "memory": 8 } },
            },
            "floes": {},
            "exposedHosts": [],
            "projections": {},
        })
    }

    fn with(overrides: Value) -> (LabSpec, VerifyConfig) {
        let mut lab = base_lab();
        merge(&mut lab, overrides);
        if let Some(clusters) = lab["clusters"].as_object_mut() {
            for (name, cluster) in clusters.iter_mut() {
                let mut full = base_cluster(name);
                merge(&mut full, cluster.clone());
                *cluster = full;
            }
        }
        (
            serde_json::from_value(lab).expect("test lab spec parses"),
            VerifyConfig::default(),
        )
    }

    #[test]
    fn exposed_hosts_are_collected_across_clusters_and_deduped() {
        let (lab, config) = with(json!({
            "clusterNames": ["mgmt", "apps"],
            "clusters": {
                "mgmt": { "exposedHosts": [
                    { "host": "b.test", "tier": "public", "namespace": "n", "bundle": "x" },
                    { "host": "a.test", "tier": "internal", "namespace": "n", "bundle": "y" },
                ]},
                "apps": { "exposedHosts": [
                    { "host": "b.test", "tier": "public", "namespace": "n", "bundle": "z" },
                ]},
            },
        }));
        let ctx = VerifyContext {
            lab_name: "l",
            lab: &lab,
            config: &config,
            package: None,
        };
        let hosts: Vec<String> = ctx
            .exposed_hosts()
            .into_iter()
            .map(|(_, h)| h.host)
            .collect();
        assert_eq!(hosts, vec!["a.test", "b.test"]);
    }

    #[test]
    fn a_lab_with_no_routes_has_nothing_to_probe() {
        let (lab, config) = with(json!({
            "clusterNames": ["app"],
            "clusters": { "app": {} },
        }));
        let ctx = VerifyContext {
            lab_name: "l",
            lab: &lab,
            config: &config,
            package: None,
        };
        assert!(ctx.exposed_hosts().is_empty());
    }

    #[test]
    fn the_ingress_follows_the_proxy_ports() {
        let plain = with(json!({
            "services": { "proxy": {
                "container": "catallaxy-proxy", "description": "proxy", "image": "haproxy",
                "ports": ["80:80"], "volumes": {},
            } },
        }));
        let ctx = VerifyContext {
            lab_name: "l",
            lab: &plain.0,
            config: &plain.1,
            package: None,
        };
        assert_eq!(ctx.ingress(), Some(("http", 80)));

        let tls = with(json!({
            "services": { "proxy": {
                "container": "catallaxy-proxy", "description": "proxy", "image": "haproxy",
                "ports": ["80:80", "443:443"], "volumes": {},
            } },
        }));
        let ctx = VerifyContext {
            lab_name: "l",
            lab: &tls.0,
            config: &tls.1,
            package: None,
        };
        assert_eq!(ctx.ingress(), Some(("https", 443)));
    }

    #[test]
    fn a_lab_with_no_proxy_has_no_ingress_to_probe_through() {
        let (lab, config) = with(json!({}));
        let ctx = VerifyContext {
            lab_name: "l",
            lab: &lab,
            config: &config,
            package: None,
        };
        assert_eq!(ctx.ingress(), None);
    }

    #[test]
    fn namespaces_come_from_the_lab_not_the_cluster() {
        let (lab, config) = with(json!({
            "clusterNames": ["app"],
            "labNamespaces": { "app": ["podinfo", "gateway"] },
        }));
        let ctx = VerifyContext {
            lab_name: "l",
            lab: &lab,
            config: &config,
            package: None,
        };
        assert_eq!(
            ctx.namespaces_for("app").to_vec(),
            vec!["podinfo", "gateway"]
        );
        assert!(ctx.namespaces_for("nonexistent").is_empty());
    }

    #[test]
    fn an_empty_runtime_context_is_no_context_at_all() {
        let (lab, config) = with(json!({
            "clusterNames": ["app"],
            "runtimeContexts": { "app": "", "obs": "k3d-obs" },
        }));
        let ctx = VerifyContext {
            lab_name: "l",
            lab: &lab,
            config: &config,
            package: None,
        };
        assert_eq!(ctx.context_for("app"), None);
        assert_eq!(ctx.context_for("obs"), Some("k3d-obs"));
    }

    #[test]
    fn the_endpoint_policy_defaults_to_probing() {
        let config: VerifyConfig = serde_json::from_value(serde_json::json!({})).unwrap();
        assert!(config.endpoints.enable);
        assert!(config.endpoints.accept_statuses.is_empty());
        assert!(config.checks.is_empty());
    }
}

#[cfg(test)]
mod probe_path_tests {
    use crate::verify::ExposedHost;

    fn host_with(paths: Vec<&str>) -> ExposedHost {
        ExposedHost {
            host: "h.test".to_string(),
            tier: "public".to_string(),
            namespace: "n".to_string(),
            bundle: "b".to_string(),
            paths: paths.into_iter().map(String::from).collect(),
        }
    }

    #[test]
    fn a_route_that_matches_everything_is_probed_at_the_root() {
        assert_eq!(host_with(vec![]).probe_path(), "/");
    }

    #[test]
    fn a_path_scoped_route_is_probed_where_it_routes() {
        assert_eq!(
            host_with(vec!["/api/v1/write"]).probe_path(),
            "/api/v1/write",
            "probing / would ask for a path the route is right to refuse"
        );
    }

    #[test]
    fn the_first_path_is_the_one_probed() {
        assert_eq!(host_with(vec!["/a", "/b"]).probe_path(), "/a");
    }
}

#[cfg(test)]
mod endpoint_status_tests {
    use crate::verify::checks::endpoints::answered;

    #[test]
    fn a_route_that_resolved_counts_as_answered() {
        for status in [200, 204, 301, 302, 399] {
            assert!(answered(status), "{status} should count as an answer");
        }
    }

    #[test]
    fn declining_the_request_still_proves_the_route() {
        assert!(answered(401));
        assert!(answered(403));
    }

    #[test]
    fn declining_the_method_still_proves_the_route() {
        assert!(
            answered(405),
            "a write-only endpoint answers GET with 405, and only the workload can"
        );
    }

    #[test]
    fn a_404_is_the_gateway_saying_no_route_matched() {
        assert!(
            !answered(404),
            "a 404 is exactly the routing failure this check exists to catch"
        );
    }

    #[test]
    fn a_server_error_is_not_an_answer() {
        for status in [500, 502, 503] {
            assert!(!answered(status), "{status} must fail");
        }
    }
}

#[cfg(test)]
mod ingress_endpoint_tests {
    use super::ingress_endpoint;

    #[test]
    fn the_default_ports_resolve_as_they_always_did() {
        assert_eq!(ingress_endpoint(&[(80, 80)]), Some(("http", 80)));
        assert_eq!(
            ingress_endpoint(&[(80, 80), (443, 443)]),
            Some(("https", 443))
        );
    }

    #[test]
    fn a_remapped_host_port_is_still_the_ingress() {
        assert_eq!(
            ingress_endpoint(&[(8080, 80)]),
            Some(("http", 8080)),
            "a lab that moves off port 80 to share a machine still has an ingress"
        );
        assert_eq!(
            ingress_endpoint(&[(8080, 80), (8443, 443)]),
            Some(("https", 8443))
        );
    }

    #[test]
    fn tls_wins_over_plaintext_whatever_the_host_port() {
        assert_eq!(
            ingress_endpoint(&[(9443, 443), (9080, 80)]),
            Some(("https", 9443))
        );
    }

    #[test]
    fn a_proxy_publishing_neither_has_no_ingress() {
        assert_eq!(ingress_endpoint(&[]), None);
        assert_eq!(ingress_endpoint(&[(5353, 53)]), None);
    }
}

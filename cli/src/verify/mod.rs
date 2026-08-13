pub mod checks;

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::domain::LabSpec;
pub use crate::domain::diagnostic::{Diagnostic, Severity};

pub const CHECK_NAMES: [&str; 5] = ["clusters", "services", "rollouts", "endpoints", "chainsaw"];

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
        let published: Vec<u16> = self
            .lab
            .services
            .get("proxy")?
            .ports
            .iter()
            .filter_map(|p| p.split(':').next()?.parse().ok())
            .collect();

        if published.contains(&443) {
            Some(("https", 443))
        } else if published.contains(&80) {
            Some(("http", 80))
        } else {
            None
        }
    }
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
                         "noTraefik": true, "noServiceLB": false, "noFlannel": false,
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

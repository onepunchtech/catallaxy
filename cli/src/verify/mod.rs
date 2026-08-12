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

#[derive(Debug, Clone, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ExposedHost {
    pub host: String,
    pub tier: String,
    pub namespace: String,
    pub bundle: String,
    #[serde(default)]
    pub paths: Vec<String>,
}

impl ExposedHost {
    pub fn probe_path(&self) -> &str {
        self.paths.first().map_or("/", |p| p.as_str())
    }
}

pub struct VerifyContext<'a> {
    pub lab_name: &'a str,
    pub lab: &'a LabSpec,
    pub config: &'a VerifyConfig,
    pub package: Option<&'a std::path::Path>,
}

impl VerifyContext<'_> {
    pub fn context_for(&self, cluster: &str) -> Option<&str> {
        self.lab
            .runtime_contexts
            .get(cluster)
            .map(String::as_str)
            .filter(|c| !c.is_empty())
    }

    pub fn namespaces_for(&self, cluster: &str) -> Vec<String> {
        self.lab
            .extra
            .get("labNamespaces")
            .and_then(|v| v.get(cluster))
            .and_then(|v| v.as_array())
            .map(|ns| {
                ns.iter()
                    .filter_map(|n| n.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default()
    }

    pub fn exposed_hosts(&self) -> Vec<(String, ExposedHost)> {
        let mut out = Vec::new();
        for (cluster, spec) in &self.lab.clusters {
            let Some(hosts) = spec.extra.get("exposedHosts").and_then(|v| v.as_array()) else {
                continue;
            };
            for host in hosts {
                if let Ok(parsed) = serde_json::from_value::<ExposedHost>(host.clone()) {
                    out.push((cluster.clone(), parsed));
                }
            }
        }
        out.sort_by(|a, b| a.1.host.cmp(&b.1.host));
        out.dedup_by(|a, b| a.1.host == b.1.host);
        out
    }

    pub fn ingress(&self) -> Option<(&'static str, u16)> {
        let published: Vec<u16> = self.lab.services["proxy"]["ports"]
            .as_array()?
            .iter()
            .filter_map(|p| p.as_str())
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

    fn ctx_from(lab: serde_json::Value, config: VerifyConfig) -> (LabSpec, VerifyConfig) {
        (
            serde_json::from_value(lab).expect("test lab spec parses"),
            config,
        )
    }

    fn with(lab: serde_json::Value) -> (LabSpec, VerifyConfig) {
        ctx_from(lab, VerifyConfig::default())
    }

    #[test]
    fn exposed_hosts_are_collected_across_clusters_and_deduped() {
        let (lab, config) = with(serde_json::json!({
            "labName": "l",
            "clusterNames": ["mgmt", "apps"],
            "clusters": {
                "mgmt": { "name": "mgmt", "exposedHosts": [
                    { "host": "b.test", "tier": "public", "namespace": "n", "bundle": "x" },
                    { "host": "a.test", "tier": "internal", "namespace": "n", "bundle": "y" },
                ]},
                "apps": { "name": "apps", "exposedHosts": [
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
        let (lab, config) = with(serde_json::json!({
            "labName": "l",
            "clusterNames": ["app"],
            "clusters": { "app": { "name": "app" } },
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
        let plain = with(serde_json::json!({
            "labName": "l",
            "services": { "proxy": { "ports": ["80:80"] } },
        }));
        let ctx = VerifyContext {
            lab_name: "l",
            lab: &plain.0,
            config: &plain.1,
            package: None,
        };
        assert_eq!(ctx.ingress(), Some(("http", 80)));

        let tls = with(serde_json::json!({
            "labName": "l",
            "services": { "proxy": { "ports": ["80:80", "443:443"] } },
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
        let (lab, config) = with(serde_json::json!({ "labName": "l" }));
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
        let (lab, config) = with(serde_json::json!({
            "labName": "l",
            "clusterNames": ["app"],
            "labNamespaces": { "app": ["podinfo", "gateway"] },
        }));
        let ctx = VerifyContext {
            lab_name: "l",
            lab: &lab,
            config: &config,
            package: None,
        };
        assert_eq!(ctx.namespaces_for("app"), vec!["podinfo", "gateway"]);
        assert!(ctx.namespaces_for("nonexistent").is_empty());
    }

    #[test]
    fn an_empty_runtime_context_is_no_context_at_all() {
        let (lab, config) = with(serde_json::json!({
            "labName": "l",
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

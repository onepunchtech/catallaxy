use std::collections::{BTreeMap, HashMap};

use crate::domain::diagnostic::{Diagnostic, Severity};

use crate::lint::manifest::K8sResource;

use super::{CheckContext, CheckRule};

pub struct Selector;

impl CheckRule for Selector {
    fn name(&self) -> &'static str {
        "selector"
    }
    fn check(&self, ctx: &CheckContext<'_>) -> Vec<Diagnostic> {
        check(ctx.resources, ctx.cluster)
    }
}

const KUBE_SYSTEM_SERVICES: &[&str] = &[
    "kube-controller-manager",
    "kube-scheduler",
    "kube-proxy",
    "kube-etcd",
    "coredns",
];

fn is_kube_system_service(r: &K8sResource) -> bool {
    if r.namespace.as_deref() != Some("kube-system") {
        return false;
    }
    KUBE_SYSTEM_SERVICES.iter().any(|svc| r.name.ends_with(svc))
}

fn is_operator_managed_workload_service(r: &K8sResource) -> bool {
    if let Some(selector) = &r.selector
        && let Some(app_name) = selector.get("app.kubernetes.io/name")
    {
        return matches!(app_name.as_str(), "prometheus" | "alertmanager");
    }
    false
}

fn check(resources: &[K8sResource], cluster: &str) -> Vec<Diagnostic> {
    let mut workloads_by_ns: HashMap<Option<&str>, Vec<&BTreeMap<String, String>>> = HashMap::new();
    for r in resources {
        if r.is_workload()
            && let Some(labels) = &r.pod_labels
        {
            workloads_by_ns
                .entry(r.namespace.as_deref())
                .or_default()
                .push(labels);
        }
    }

    let mut diags = Vec::new();

    for r in resources {
        if !r.is_service() {
            continue;
        }
        if r.has_lint_skip("selector") {
            continue;
        }
        if is_kube_system_service(r) || is_operator_managed_workload_service(r) {
            continue;
        }

        let selector = match &r.selector {
            Some(s) => s,
            None => continue,
        };

        let workloads = workloads_by_ns
            .get(&r.namespace.as_deref())
            .map(|v| v.as_slice())
            .unwrap_or(&[]);

        let has_match = workloads
            .iter()
            .any(|labels| selector.iter().all(|(k, v)| labels.get(k) == Some(v)));

        if !has_match {
            diags.push(Diagnostic {
                severity: Severity::Warning,
                check: "selector",
                cluster: cluster.to_string(),
                file: r.source_file.clone(),
                resource: r.display_id(),
                message: "no matching workload found for service selector".to_string(),
            });
        }
    }

    diags
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lint::rules::test_util::make_resource;

    fn deployment(name: &str, namespace: &str, app: &str) -> K8sResource {
        make_resource(&format!(
            "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: {name}\n  namespace: {namespace}\nspec:\n  template:\n    metadata:\n      labels:\n        app: {app}\n"
        ))
    }

    fn service(name: &str, namespace: &str, app: &str) -> K8sResource {
        make_resource(&format!(
            "apiVersion: v1\nkind: Service\nmetadata:\n  name: {name}\n  namespace: {namespace}\nspec:\n  selector:\n    app: {app}\n"
        ))
    }

    #[test]
    fn passes_when_selector_matches_workload_in_same_namespace() {
        let svc = service("api", "apps", "api");
        let dep = deployment("api", "apps", "api");
        assert!(check(&[svc, dep], "c").is_empty());
    }

    #[test]
    fn flags_selector_without_matching_workload() {
        let svc = service("api", "apps", "api");
        let diags = check(&[svc], "c");
        assert_eq!(diags.len(), 1);
        assert_eq!(diags[0].severity, Severity::Warning);
        assert!(diags[0].message.contains("no matching workload"));
    }

    #[test]
    fn same_labels_in_different_namespace_do_not_match() {
        let svc = service("api", "apps", "api");
        let dep = deployment("api", "other", "api");
        let diags = check(&[svc, dep], "c");
        assert_eq!(diags.len(), 1);
    }

    #[test]
    fn kube_system_services_are_exempt() {
        let svc = make_resource(
            "apiVersion: v1\nkind: Service\nmetadata:\n  name: kube-scheduler\n  namespace: kube-system\nspec:\n  selector:\n    component: kube-scheduler\n",
        );
        assert!(check(&[svc], "c").is_empty());
    }

    #[test]
    fn operator_managed_prometheus_service_is_exempt() {
        let svc = make_resource(
            "apiVersion: v1\nkind: Service\nmetadata:\n  name: prometheus\n  namespace: monitoring\nspec:\n  selector:\n    app.kubernetes.io/name: prometheus\n",
        );
        assert!(check(&[svc], "c").is_empty());
    }

    #[test]
    fn lint_skip_annotation_disables_check() {
        let svc = make_resource(
            "apiVersion: v1\nkind: Service\nmetadata:\n  name: api\n  namespace: apps\n  annotations:\n    catallaxy.io/lint-skip: selector\nspec:\n  selector:\n    app: api\n",
        );
        assert!(check(&[svc], "c").is_empty());
    }
}

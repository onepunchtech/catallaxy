use std::collections::HashSet;

use crate::domain::diagnostic::{Diagnostic, Severity};

use crate::lint::manifest::K8sResource;

use super::{CheckContext, CheckRule};

pub struct Prefix;

impl CheckRule for Prefix {
    fn name(&self) -> &'static str {
        "prefix"
    }
    fn check(&self, ctx: &CheckContext<'_>) -> Vec<Diagnostic> {
        check(ctx.resources, ctx.cluster, ctx.prefix, ctx.lab_namespaces)
    }
}

fn check(
    resources: &[K8sResource],
    cluster: &str,
    prefix: &str,
    lab_namespaces: &[String],
) -> Vec<Diagnostic> {
    if prefix.is_empty() {
        return Vec::new();
    }

    let expected_prefix = format!("{prefix}-");
    let lab_ns_set: HashSet<&str> = lab_namespaces.iter().map(|s| s.as_str()).collect();
    let mut diags = Vec::new();

    for r in resources {
        if r.is_crd() {
            continue;
        }

        if !r.name.starts_with(&expected_prefix) {
            diags.push(Diagnostic {
                severity: Severity::Error,
                check: "prefix",
                cluster: cluster.to_string(),
                file: r.source_file.clone(),
                resource: r.display_id(),
                message: format!(
                    "resource name '{}' missing prefix '{}'",
                    r.name, expected_prefix
                ),
            });
        }

        if let Some(ns) = &r.namespace {
            if lab_ns_set.contains(ns.as_str()) {
                diags.push(Diagnostic {
                    severity: Severity::Error,
                    check: "prefix",
                    cluster: cluster.to_string(),
                    file: r.source_file.clone(),
                    resource: r.display_id(),
                    message: format!(
                        "namespace '{}' not prefixed (expected '{}{}')",
                        ns, expected_prefix, ns
                    ),
                });
            }
        }
    }

    diags
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lint::rules::test_util::make_resource;

    #[test]
    fn no_prefix_configured_is_noop() {
        let r = make_resource("apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: whatever\n");
        assert!(check(&[r], "c", "", &[]).is_empty());
    }

    #[test]
    fn passes_prefixed_name() {
        let r = make_resource("apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: lab-cfg\n");
        assert!(check(&[r], "c", "lab", &[]).is_empty());
    }

    #[test]
    fn flags_missing_prefix_on_name() {
        let r = make_resource("apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cfg\n");
        let diags = check(&[r], "c", "lab", &[]);
        assert_eq!(diags.len(), 1);
        assert!(diags[0].message.contains("missing prefix 'lab-'"));
    }

    #[test]
    fn crds_are_exempt() {
        let r = make_resource(
            "apiVersion: apiextensions.k8s.io/v1\nkind: CustomResourceDefinition\nmetadata:\n  name: widgets.example.io\n",
        );
        assert!(check(&[r], "c", "lab", &[]).is_empty());
    }

    #[test]
    fn flags_unprefixed_lab_namespace() {
        let r = make_resource(
            "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: lab-cfg\n  namespace: apps\n",
        );
        let diags = check(&[r], "c", "lab", &["apps".to_string()]);
        assert_eq!(diags.len(), 1);
        assert!(diags[0].message.contains("namespace 'apps' not prefixed"));
    }
}

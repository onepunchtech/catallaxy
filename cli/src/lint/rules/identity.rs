use std::collections::HashMap;

use crate::domain::diagnostic::{Diagnostic, Severity};

use crate::lint::manifest::K8sResource;

use super::{CheckContext, CheckRule};

pub struct Identity;

impl CheckRule for Identity {
    fn name(&self) -> &'static str {
        "identity"
    }
    fn check(&self, ctx: &CheckContext<'_>) -> Vec<Diagnostic> {
        check(ctx.resources, ctx.cluster)
    }
}

fn check(resources: &[K8sResource], cluster: &str) -> Vec<Diagnostic> {
    let mut seen: HashMap<(String, String, Option<String>, String), &K8sResource> = HashMap::new();
    let mut diags = Vec::new();

    for r in resources {
        let key = (
            r.api_version.clone(),
            r.kind.clone(),
            r.namespace.clone(),
            r.name.clone(),
        );

        if let Some(first) = seen.get(&key) {
            diags.push(Diagnostic {
                severity: Severity::Error,
                check: "identity",
                cluster: cluster.to_string(),
                file: r.source_file.clone(),
                resource: r.display_id(),
                message: format!(
                    "duplicate resource identity {}/{} (first seen in {})",
                    r.api_version,
                    r.kind,
                    first.source_file.display()
                ),
            });
        } else {
            seen.insert(key, r);
        }
    }

    diags
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lint::rules::test_util::make_resource;

    #[test]
    fn passes_distinct_resources() {
        let a = make_resource(
            "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: a\n  namespace: n\n",
        );
        let b = make_resource(
            "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: b\n  namespace: n\n",
        );
        assert!(check(&[a, b], "c").is_empty());
    }

    #[test]
    fn flags_duplicate_identity() {
        let a = make_resource(
            "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: same\n  namespace: n\n",
        );
        let b = make_resource(
            "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: same\n  namespace: n\n",
        );
        let diags = check(&[a, b], "c");
        assert_eq!(diags.len(), 1);
        assert!(diags[0].message.contains("duplicate"));
    }

    #[test]
    fn same_name_different_namespace_is_ok() {
        let a = make_resource(
            "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cfg\n  namespace: a\n",
        );
        let b = make_resource(
            "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cfg\n  namespace: b\n",
        );
        assert!(check(&[a, b], "c").is_empty());
    }
}

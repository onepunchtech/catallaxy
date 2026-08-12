use crate::domain::diagnostic::{Diagnostic, Severity};

use crate::lint::manifest::K8sResource;

use super::{CheckContext, CheckRule};

pub struct Schema;

impl CheckRule for Schema {
    fn name(&self) -> &'static str {
        "schema"
    }
    fn check(&self, ctx: &CheckContext<'_>) -> Vec<Diagnostic> {
        check(ctx.resources, ctx.cluster)
    }
}

fn check(resources: &[K8sResource], cluster: &str) -> Vec<Diagnostic> {
    let mut diags = Vec::new();

    for r in resources {
        if r.api_version.is_empty() {
            diags.push(Diagnostic {
                severity: Severity::Error,
                check: "schema",
                cluster: cluster.to_string(),
                file: r.source_file.clone(),
                resource: r.display_id(),
                message: "missing apiVersion".to_string(),
            });
        }
        if r.kind.is_empty() {
            diags.push(Diagnostic {
                severity: Severity::Error,
                check: "schema",
                cluster: cluster.to_string(),
                file: r.source_file.clone(),
                resource: r.display_id(),
                message: "missing kind".to_string(),
            });
        }
        if r.name.is_empty() {
            diags.push(Diagnostic {
                severity: Severity::Error,
                check: "schema",
                cluster: cluster.to_string(),
                file: r.source_file.clone(),
                resource: r.display_id(),
                message: "missing metadata.name".to_string(),
            });
        }
    }

    diags
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lint::rules::test_util::make_resource;

    #[test]
    fn passes_complete_resource() {
        let r = make_resource("apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cm\n");
        assert!(check(&[r], "c").is_empty());
    }

    #[test]
    fn flags_missing_api_version() {
        let r = make_resource("kind: ConfigMap\nmetadata:\n  name: cm\n");
        let diags = check(&[r], "c");
        assert_eq!(diags.len(), 1);
        assert!(diags[0].message.contains("apiVersion"));
    }

    #[test]
    fn flags_missing_name() {
        let r = make_resource("apiVersion: v1\nkind: ConfigMap\nmetadata: {}\n");
        let diags = check(&[r], "c");
        assert_eq!(diags.len(), 1);
        assert!(diags[0].message.contains("metadata.name"));
    }
}

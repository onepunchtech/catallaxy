use crate::domain::diagnostic::{Diagnostic, Severity};

use crate::lint::manifest::K8sResource;

use super::crd_schema::{crd_key, extract_crd_schemas};
use super::{CheckContext, CheckRule};

const BUILTIN_API_GROUPS: &[&str] = &[
    "",
    "apps",
    "batch",
    "autoscaling",
    "policy",
    "networking.k8s.io",
    "rbac.authorization.k8s.io",
    "storage.k8s.io",
    "admissionregistration.k8s.io",
    "apiextensions.k8s.io",
    "apiregistration.k8s.io",
    "certificates.k8s.io",
    "coordination.k8s.io",
    "discovery.k8s.io",
    "events.k8s.io",
    "flowcontrol.apiserver.k8s.io",
    "node.k8s.io",
    "scheduling.k8s.io",
];

pub struct MissingCrd;

impl CheckRule for MissingCrd {
    fn name(&self) -> &'static str {
        "missing-crd"
    }
    fn check(&self, ctx: &CheckContext<'_>) -> Vec<Diagnostic> {
        check(ctx.resources, ctx.cluster)
    }
}

fn api_group(api_version: &str) -> &str {
    match api_version.rsplit_once('/') {
        Some((group, _)) => group,
        None => "",
    }
}

fn check(resources: &[K8sResource], cluster: &str) -> Vec<Diagnostic> {
    let schemas = extract_crd_schemas(resources);
    let mut diags = Vec::new();

    for r in resources {
        if r.is_crd() {
            continue;
        }

        let group = api_group(&r.api_version);

        if BUILTIN_API_GROUPS.contains(&group) {
            continue;
        }

        let key = crd_key(&r.api_version, &r.kind);
        if schemas.contains_key(&key) {
            continue;
        }

        diags.push(Diagnostic {
            severity: Severity::Warning,
            check: "missing-crd",
            cluster: cluster.to_string(),
            file: r.source_file.clone(),
            resource: r.display_id(),
            message: format!(
                "no CRD found for {}/{}, will fail if CRD is not installed at apply time",
                r.api_version, r.kind
            ),
        });
    }

    diags
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lint::rules::test_util::make_resource;

    fn widget_crd() -> K8sResource {
        make_resource(
            r#"
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: widgets.example.io
spec:
  group: example.io
  names:
    kind: Widget
  versions:
    - name: v1
      schema:
        openAPIV3Schema:
          type: object
"#,
        )
    }

    fn widget_cr() -> K8sResource {
        make_resource(
            "apiVersion: example.io/v1\nkind: Widget\nmetadata:\n  name: w\n  namespace: default\n",
        )
    }

    #[test]
    fn builtin_apps_group_needs_no_crd() {
        let dep = make_resource(
            "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: app\n  namespace: apps\n",
        );
        assert!(check(&[dep], "c").is_empty());
    }

    #[test]
    fn core_v1_needs_no_crd() {
        let cm = make_resource(
            "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cfg\n  namespace: apps\n",
        );
        assert!(check(&[cm], "c").is_empty());
    }

    #[test]
    fn passes_when_matching_crd_is_present() {
        let diags = check(&[widget_crd(), widget_cr()], "c");
        assert!(diags.is_empty());
    }

    #[test]
    fn flags_cr_without_matching_crd() {
        let diags = check(&[widget_cr()], "c");
        assert_eq!(diags.len(), 1);
        assert!(
            diags[0]
                .message
                .contains("no CRD found for example.io/v1/Widget")
        );
    }

    #[test]
    fn crds_themselves_are_not_flagged() {
        let diags = check(&[widget_crd()], "c");
        assert!(diags.is_empty());
    }
}

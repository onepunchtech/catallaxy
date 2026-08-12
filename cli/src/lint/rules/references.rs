use std::collections::HashSet;

use crate::domain::diagnostic::{Diagnostic, Severity};

use crate::lint::manifest::K8sResource;

use super::{CheckContext, CheckRule};

pub struct References;

impl CheckRule for References {
    fn name(&self) -> &'static str {
        "reference"
    }
    fn check(&self, ctx: &CheckContext<'_>) -> Vec<Diagnostic> {
        let materialised: HashSet<&str> = ctx
            .cluster_meta
            .map(|m| m.runtime_materialised.iter().map(String::as_str).collect())
            .unwrap_or_default();
        check(
            ctx.resources,
            ctx.cluster,
            ctx.projection_names,
            &materialised,
        )
    }
}

fn promised_by_custom_resources(resources: &[K8sResource]) -> HashSet<(Option<&str>, String)> {
    let mut promised = HashSet::new();
    for r in resources {
        if r.kind == "Certificate"
            && r.api_version.starts_with("cert-manager.io/")
            && let Some(name) = r
                .raw
                .get("spec")
                .and_then(|s| s.get("secretName"))
                .and_then(|v| v.as_str())
        {
            promised.insert((r.namespace.as_deref(), name.to_string()));
        }
        if r.kind == "Cluster" && r.api_version.starts_with("postgresql.cnpg.io/") {
            promised.insert((r.namespace.as_deref(), format!("{}-app", r.name)));
        }
        if r.kind == "SetupKey" && r.api_version.starts_with("netbird.io/") {
            promised.insert((r.namespace.as_deref(), format!("setup-key-{}", r.name)));
        }
    }
    promised
}

fn namespaces_with_jobs(resources: &[K8sResource]) -> HashSet<Option<&str>> {
    resources
        .iter()
        .filter(|r| r.kind == "Job" || r.kind == "CronJob")
        .map(|r| r.namespace.as_deref())
        .collect()
}

fn check(
    resources: &[K8sResource],
    cluster: &str,
    projection_names: &HashSet<String>,
    runtime_materialised: &HashSet<&str>,
) -> Vec<Diagnostic> {
    let mut configmaps: HashSet<(Option<&str>, &str)> = HashSet::new();
    let mut secrets: HashSet<(Option<&str>, &str)> = HashSet::new();

    for r in resources {
        if r.is_configmap() {
            configmaps.insert((r.namespace.as_deref(), &r.name));
        }
        if r.is_secret() {
            secrets.insert((r.namespace.as_deref(), &r.name));
        }
    }

    let promised = promised_by_custom_resources(resources);
    let job_namespaces = namespaces_with_jobs(resources);

    let mut diags = Vec::new();

    for r in resources {
        if r.has_lint_skip("reference") {
            continue;
        }

        for cm_ref in &r.configmap_refs {
            if configmaps.contains(&(r.namespace.as_deref(), cm_ref.as_str())) {
                continue;
            }
            if runtime_materialised.contains(cm_ref.as_str()) {
                continue;
            }
            if promised.contains(&(r.namespace.as_deref(), cm_ref.clone()))
                || job_namespaces.contains(&r.namespace.as_deref())
            {
                continue;
            }
            diags.push(Diagnostic {
                severity: Severity::Error,
                check: "reference",
                cluster: cluster.to_string(),
                file: r.source_file.clone(),
                resource: r.display_id(),
                message: format!("references ConfigMap '{}' which does not exist", cm_ref),
            });
        }
        for secret_ref in &r.secret_refs {
            if secrets.contains(&(r.namespace.as_deref(), secret_ref.as_str())) {
                continue;
            }
            if projection_names.contains(secret_ref.as_str()) {
                continue;
            }
            if runtime_materialised.contains(secret_ref.as_str()) {
                continue;
            }
            if promised.contains(&(r.namespace.as_deref(), secret_ref.clone()))
                || job_namespaces.contains(&r.namespace.as_deref())
            {
                continue;
            }
            diags.push(Diagnostic {
                severity: Severity::Error,
                check: "reference",
                cluster: cluster.to_string(),
                file: r.source_file.clone(),
                resource: r.display_id(),
                message: format!("references Secret '{}' which does not exist", secret_ref),
            });
        }
    }

    diags
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lint::rules::test_util::make_resource;

    fn deployment_with_envfrom(
        namespace: &str,
        cm: Option<&str>,
        secret: Option<&str>,
    ) -> K8sResource {
        let mut env_from = String::new();
        if let Some(name) = cm {
            env_from.push_str(&format!(
                "            - configMapRef:\n                name: {name}\n"
            ));
        }
        if let Some(name) = secret {
            env_from.push_str(&format!(
                "            - secretRef:\n                name: {name}\n"
            ));
        }
        make_resource(&format!(
            "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: app\n  namespace: {namespace}\nspec:\n  template:\n    metadata:\n      labels:\n        app: app\n    spec:\n      containers:\n      - name: c\n        image: nginx\n        envFrom:\n{env_from}"
        ))
    }

    fn configmap(name: &str, namespace: &str) -> K8sResource {
        make_resource(&format!(
            "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: {name}\n  namespace: {namespace}\ndata:\n  k: v\n"
        ))
    }

    fn secret(name: &str, namespace: &str) -> K8sResource {
        make_resource(&format!(
            "apiVersion: v1\nkind: Secret\nmetadata:\n  name: {name}\n  namespace: {namespace}\ntype: Opaque\n"
        ))
    }

    #[test]
    fn passes_when_referenced_configmap_exists() {
        let dep = deployment_with_envfrom("apps", Some("cfg"), None);
        let cm = configmap("cfg", "apps");
        let names = HashSet::new();
        assert!(check(&[dep, cm], "c", &names, &HashSet::new()).is_empty());
    }

    #[test]
    fn flags_missing_configmap_reference() {
        let dep = deployment_with_envfrom("apps", Some("cfg"), None);
        let names = HashSet::new();
        let diags = check(&[dep], "c", &names, &HashSet::new());
        assert_eq!(diags.len(), 1);
        assert!(diags[0].message.contains("ConfigMap 'cfg'"));
    }

    #[test]
    fn flags_missing_secret_reference() {
        let dep = deployment_with_envfrom("apps", None, Some("api-key"));
        let names = HashSet::new();
        let diags = check(&[dep], "c", &names, &HashSet::new());
        assert_eq!(diags.len(), 1);
        assert!(diags[0].message.contains("Secret 'api-key'"));
    }

    fn certificate(secret_name: &str, namespace: &str) -> K8sResource {
        make_resource(&format!(
            "apiVersion: cert-manager.io/v1\nkind: Certificate\nmetadata:\n  name: c\n  namespace: {namespace}\nspec:\n  secretName: {secret_name}\n"
        ))
    }

    fn job(namespace: &str) -> K8sResource {
        make_resource(&format!(
            "apiVersion: batch/v1\nkind: Job\nmetadata:\n  name: bootstrap\n  namespace: {namespace}\nspec:\n  template:\n    spec:\n      containers: []\n"
        ))
    }

    #[test]
    fn secret_promised_by_a_certificate_is_exempt() {
        let dep = deployment_with_envfrom("apps", None, Some("api-tls"));
        let cert = certificate("api-tls", "apps");
        let names = HashSet::new();
        assert!(check(&[dep, cert], "c", &names, &HashSet::new()).is_empty());
    }

    #[test]
    fn tls_suffix_alone_no_longer_exempts() {
        let dep = deployment_with_envfrom("apps", None, Some("api-tls"));
        let names = HashSet::new();
        assert_eq!(check(&[dep], "c", &names, &HashSet::new()).len(), 1);
    }

    #[test]
    fn job_in_namespace_exempts_references() {
        let dep = deployment_with_envfrom("apps", None, Some("minted-at-runtime"));
        let names = HashSet::new();
        assert!(check(&[dep, job("apps")], "c", &names, &HashSet::new()).is_empty());
    }

    #[test]
    fn projection_names_satisfy_secret_reference() {
        let dep = deployment_with_envfrom("apps", None, Some("api-key"));
        let mut names = HashSet::new();
        names.insert("api-key".to_string());
        assert!(check(&[dep], "c", &names, &HashSet::new()).is_empty());
    }

    #[test]
    fn exported_runtime_object_is_exempt() {
        let dep = deployment_with_envfrom("apps", Some("lab-ca-bundle"), None);
        let names = HashSet::new();
        let materialised = HashSet::from(["lab-ca-bundle"]);
        assert!(check(&[dep], "c", &names, &materialised).is_empty());
    }

    #[test]
    fn unexported_runtime_object_is_reported() {
        let dep = deployment_with_envfrom("apps", Some("lab-ca-bundle"), None);
        let names = HashSet::new();
        let diags = check(&[dep], "c", &names, &HashSet::new());
        assert_eq!(diags.len(), 1);
        assert!(diags[0].message.contains("lab-ca-bundle"));
    }

    #[test]
    fn secret_in_different_namespace_still_flags() {
        let dep = deployment_with_envfrom("apps", None, Some("shared"));
        let sec = secret("shared", "other");
        let names = HashSet::new();
        let diags = check(&[dep, sec], "c", &names, &HashSet::new());
        assert_eq!(diags.len(), 1);
    }
}

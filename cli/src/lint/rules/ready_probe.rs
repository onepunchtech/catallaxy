use std::collections::HashSet;
use std::path::Path;

use crate::domain::diagnostic::{Diagnostic, Severity};
use crate::io::ssa::WaveMeta;
use crate::lint::manifest::K8sResource;

use super::{CheckContext, CheckRule};

pub struct ReadyProbeTargets;

impl CheckRule for ReadyProbeTargets {
    fn name(&self) -> &'static str {
        "ready-probe"
    }
    fn check(&self, ctx: &CheckContext<'_>) -> Vec<Diagnostic> {
        check(ctx.resources, ctx.cluster, ctx.manifest_dir)
    }
}

fn mints_at_runtime(r: &K8sResource) -> bool {
    if r.kind == "Job" || r.kind == "CronJob" {
        return true;
    }
    let group = r.api_version.split('/').next().unwrap_or("");
    !matches!(
        group,
        "v1" | "apps" | "batch" | "networking.k8s.io" | "rbac.authorization.k8s.io" | "policy"
    )
}

fn normalise_kind(k: &str) -> String {
    let k = k.to_ascii_lowercase();
    let k = match k.as_str() {
        "deploy" | "deployments" => "deployment",
        "sts" | "statefulsets" => "statefulset",
        "ds" | "daemonsets" => "daemonset",
        "cm" | "configmaps" => "configmap",
        "secrets" => "secret",
        "svc" | "services" => "service",
        "jobs" => "job",
        "po" | "pods" => "pod",
        other => other,
    };
    k.to_string()
}

fn check(resources: &[K8sResource], cluster: &str, manifest_dir: &Path) -> Vec<Diagnostic> {
    let wave_meta_path = manifest_dir.join(".wave-meta");
    let Ok(raw) = std::fs::read_to_string(&wave_meta_path) else {
        return Vec::new();
    };
    let Ok(meta) = serde_json::from_str::<WaveMeta>(&raw) else {
        return Vec::new();
    };

    let mut diags = Vec::new();

    for wave in &meta.waves {
        for bundle in &wave.bundles {
            if !bundle.has_content {
                continue;
            }
            let Some(probe) = &bundle.ready_probe else {
                continue;
            };
            let Some(target) = probe.target() else {
                continue;
            };
            let Some((kind_raw, name)) = target.split_once('/') else {
                continue;
            };
            let want_kind = normalise_kind(kind_raw);

            let kinds_with_name: HashSet<String> = resources
                .iter()
                .filter(|r| r.name == name)
                .map(|r| normalise_kind(&r.kind))
                .collect();

            if kinds_with_name.contains(&want_kind) {
                continue;
            }

            if !kinds_with_name.is_empty() {
                let mut found: Vec<&str> = kinds_with_name.iter().map(String::as_str).collect();
                found.sort_unstable();
                diags.push(diag(
                    cluster,
                    &bundle.key,
                    format!(
                        "readyProbe waits on '{target}', but '{name}' is rendered as {}: \
                         the probe blocks until its timeout and then fails the deploy",
                        found.join(", ")
                    ),
                ));
                continue;
            }

            let bundle_mints = resources
                .iter()
                .filter(|r| {
                    r.source_file
                        .to_string_lossy()
                        .contains(bundle.dir.as_str())
                })
                .any(mints_at_runtime);

            if !bundle_mints {
                diags.push(diag(
                    cluster,
                    &bundle.key,
                    format!(
                        "readyProbe waits on '{target}', which nothing in this bundle renders \
                         and nothing here can mint after apply — the probe blocks until its \
                         timeout and then fails the deploy"
                    ),
                ));
            }
        }
    }

    diags
}

fn diag(cluster: &str, bundle: &str, message: String) -> Diagnostic {
    Diagnostic {
        severity: Severity::Error,
        check: "ready-probe",
        cluster: cluster.to_string(),
        file: std::path::PathBuf::new(),
        resource: format!("bundle/{bundle}"),
        message,
    }
}

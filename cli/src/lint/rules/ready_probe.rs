use std::collections::HashSet;

use crate::domain::diagnostic::{Diagnostic, Severity};
use crate::io::ssa::{WaveBundle, WaveMeta};
use crate::lint::manifest::K8sResource;

use super::{CheckContext, CheckRule};

pub struct ReadyProbeTargets;

impl CheckRule for ReadyProbeTargets {
    fn name(&self) -> &'static str {
        "ready-probe"
    }
    fn check(&self, ctx: &CheckContext<'_>) -> Vec<Diagnostic> {
        match ctx.wave_meta {
            Some(meta) => check(ctx.resources, ctx.cluster, meta, ctx.projection_names),
            None => Vec::new(),
        }
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

/// Bundles that satisfy any of `requires`, via the provides index. A probe may
/// legitimately wait on something a bundle we are ordered after produces at
/// runtime; that is the whole reason `requires` exists.
fn required_bundles<'a>(bundle: &WaveBundle, meta: &'a WaveMeta) -> Vec<&'a WaveBundle> {
    meta.waves
        .iter()
        .flat_map(|w| w.bundles.iter())
        .filter(|b| b.provides.iter().any(|t| bundle.requires.contains(t)))
        .collect()
}

fn check(
    resources: &[K8sResource],
    cluster: &str,
    meta: &WaveMeta,
    projection_names: &HashSet<String>,
) -> Vec<Diagnostic> {
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

            // A projected Secret never appears in the rendered tree: the value
            // is decrypted and applied at deploy. The projection machinery
            // already asserts it lands no later than its consumer.
            if want_kind == "secret" && projection_names.contains(name) {
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

            let mut minting_dirs = vec![bundle.dir.as_str()];
            let required = required_bundles(bundle, meta);
            minting_dirs.extend(required.iter().map(|b| b.dir.as_str()));

            let something_mints = resources
                .iter()
                .filter(|r| {
                    let file = r.source_file.to_string_lossy().to_string();
                    minting_dirs.iter().any(|d| file.contains(d))
                })
                .any(mints_at_runtime);

            if !something_mints {
                diags.push(diag(
                    cluster,
                    &bundle.key,
                    format!(
                        "readyProbe waits on '{target}', which nothing renders and nothing \
                         this bundle requires can mint after apply — the probe blocks until \
                         its timeout and then fails the deploy"
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

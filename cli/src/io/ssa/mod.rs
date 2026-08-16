use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::thread::sleep;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use console::style;

use crate::apply::{
    ProjectionConfig, ProjectionSource, inject_projections_with, parse_projections,
};
use crate::config::Context as CataContext;
use crate::domain::SecretsCache;
use crate::domain::{ClusterSpec, SecretsSpec};
use crate::io;

mod probe;

pub use probe::ReadyProbe;
use probe::run_ready_probe;

const BUNDLE_APPLY_ATTEMPTS: u32 = 4;
const PHASE_APPLY_BACKOFF: Duration = Duration::from_secs(6);

pub struct ApplyManifests<'a> {
    pub kube_context: &'a str,
    pub manifest_root: &'a Path,
    pub field_manager: &'a str,
    pub wait_timeout_seconds: u64,
    pub dry_run: bool,
    pub cluster: Option<&'a ClusterSpec>,
    pub lab_name: &'a str,
    pub secrets_spec: &'a SecretsSpec,
    pub secrets_cache: Option<&'a SecretsCache>,
}

pub fn apply_manifest_root(ctx: &CataContext, opts: ApplyManifests<'_>) -> Result<()> {
    let ApplyManifests {
        manifest_root,
        wait_timeout_seconds,
        ..
    } = opts;
    if !manifest_root.exists() {
        bail!(
            "manifest root not found at {}. Rebuild the lab package.",
            manifest_root.display(),
        );
    }

    let timeout_str = format!("{wait_timeout_seconds}s");

    let wave_meta_path = manifest_root.join(".wave-meta");
    if !wave_meta_path.exists() {
        bail!(
            "no .wave-meta at {}: the manifest tree was rendered by an \
             older catallaxy. Re-render the lab.",
            manifest_root.display()
        );
    }
    apply_wave_ordered(ctx, &opts, &wave_meta_path, &timeout_str)
}

pub fn read_wave_meta(manifest_dir: &Path) -> Option<WaveMeta> {
    let raw = fs::read_to_string(manifest_dir.join(".wave-meta")).ok()?;
    serde_json::from_str(&raw).ok()
}

#[derive(serde::Deserialize, Debug)]
pub struct WaveMeta {
    pub waves: Vec<Wave>,
}

#[derive(serde::Deserialize, Debug)]
pub struct Wave {
    pub index: usize,
    pub bundles: Vec<WaveBundle>,
}

#[derive(serde::Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct WaveBundle {
    pub key: String,
    pub dir: String,
    #[serde(default)]
    pub ready_probe: Option<ReadyProbe>,
    pub has_content: bool,
    #[serde(default)]
    pub requires: Vec<String>,
    #[serde(default)]
    pub provides: Vec<String>,
}

fn apply_wave_ordered(
    ctx: &CataContext,
    opts: &ApplyManifests<'_>,
    wave_meta_path: &Path,
    timeout_str: &str,
) -> Result<()> {
    let &ApplyManifests {
        kube_context,
        manifest_root,
        field_manager,
        dry_run,
        cluster,
        lab_name,
        secrets_spec,
        secrets_cache,
        ..
    } = opts;
    let raw = fs::read_to_string(wave_meta_path)
        .with_context(|| format!("reading .wave-meta at {}", wave_meta_path.display()))?;
    let meta: WaveMeta = serde_json::from_str(&raw)
        .with_context(|| format!("parsing .wave-meta at {}", wave_meta_path.display()))?;

    let projections: HashMap<String, ProjectionConfig> = cluster
        .map(|c| parse_projections(&c.projections))
        .unwrap_or_default();

    let projections_for_wave = |wave: &Wave| -> Vec<(String, ProjectionConfig)> {
        wave.bundles
            .iter()
            .filter_map(|b| b.key.strip_prefix("projection/"))
            .filter_map(|name| projections.get(name).map(|p| (name.to_string(), p.clone())))
            .collect()
    };

    println!(
        "{} Applying {wave_count} wave(s) via kubectl SSA on '{kube_context}' \
         (field-manager={field_manager})",
        style(">>>").cyan(),
        wave_count = meta.waves.len(),
    );

    for wave in &meta.waves {
        let bundle_count = wave.bundles.len();
        println!(
            "\n{} Wave {:03} ({bundle_count} bundle{})",
            style(">>>").cyan(),
            wave.index + 1,
            if bundle_count == 1 { "" } else { "s" },
        );

        let wave_projections = projections_for_wave(wave);
        if !wave_projections.is_empty() {
            inject_projections_ssa(
                ctx,
                kube_context,
                &ProjectionSource {
                    lab_name,
                    secrets: secrets_spec,
                    pre_cache: secrets_cache.map(|v| &**v),
                },
                &wave_projections,
                field_manager,
                dry_run,
            )?;
        }

        apply_wave_bundles(ctx, opts, wave, manifest_root, timeout_str)?;
        await_wave_bundles(ctx, opts, wave, manifest_root, timeout_str)?;
    }

    println!(
        "\n{} SSA wave apply complete on '{kube_context}'",
        style(">>>").green(),
    );
    Ok(())
}

fn apply_bundle_with_retry(
    kube_context: &str,
    field_manager: &str,
    bundle_key: &str,
    bundle_dir: &Path,
    dry_run: bool,
) -> Result<()> {
    if dry_run {
        println!(
            "{} Would kubectl apply bundle '{bundle_key}' from {}",
            style(">>>").yellow(),
            bundle_dir.display(),
        );
        return Ok(());
    }
    let mut last_err: Option<anyhow::Error> = None;
    for attempt in 1..=BUNDLE_APPLY_ATTEMPTS {
        let status = crate::io::kubectl::command()
            .args([
                "--context",
                kube_context,
                "apply",
                "--server-side",
                "--force-conflicts",
                "--field-manager",
                field_manager,
                "-f",
            ])
            .arg(bundle_dir)
            .arg("--recursive")
            .status()
            .context("running kubectl apply --server-side for bundle")?;
        if status.success() {
            println!("{} Applied bundle '{bundle_key}'", style(">>>").green(),);
            return Ok(());
        }
        if attempt == BUNDLE_APPLY_ATTEMPTS {
            last_err = Some(anyhow::anyhow!(
                "kubectl apply exited with {status} on bundle '{bundle_key}'"
            ));
            break;
        }
        println!(
            "{} kubectl apply of bundle '{bundle_key}' failed (attempt {attempt}/{BUNDLE_APPLY_ATTEMPTS}); \
             sleeping {backoff}s and retrying.",
            style(">>>").yellow(),
            backoff = PHASE_APPLY_BACKOFF.as_secs(),
        );
        sleep(PHASE_APPLY_BACKOFF);
    }
    bail!(
        "kubectl apply of bundle '{bundle_key}' failed after {BUNDLE_APPLY_ATTEMPTS} attempts: {}",
        last_err.map(|e| e.to_string()).unwrap_or_default(),
    );
}

fn wait_bundle_crds(
    _ctx: &CataContext,
    kube_context: &str,
    bundle_key: &str,
    bundle_dir: &Path,
    timeout: &str,
    dry_run: bool,
) -> Result<()> {
    let marker = bundle_dir.join(".crd-wait");
    if !marker.exists() {
        return Ok(());
    }
    let content =
        fs::read_to_string(&marker).with_context(|| format!("reading {}", marker.display()))?;
    let crds: Vec<&str> = content
        .lines()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty())
        .collect();
    if crds.is_empty() {
        return Ok(());
    }
    if dry_run {
        println!(
            "{} Would wait for {} CRD(s) from '{bundle_key}' to be Established",
            style(">>>").yellow(),
            crds.len(),
        );
        return Ok(());
    }
    println!(
        "{} Waiting for {} CRD(s) from '{bundle_key}' to be Established",
        style(">>>").cyan(),
        crds.len(),
    );
    for crd in crds {
        io::kubectl::wait_crd_established(kube_context, crd, timeout)?;
    }
    Ok(())
}

fn inject_projections_ssa(
    ctx: &CataContext,
    kube_context: &str,
    source: &ProjectionSource<'_>,
    projections: &[(String, ProjectionConfig)],
    field_manager: &str,
    dry_run: bool,
) -> Result<()> {
    inject_projections_with(ctx, source, projections, |secret_dir, secret_name| {
        if dry_run {
            println!(
                "{} Would kubectl apply --context {kube_context} --server-side \
                     --force-conflicts --field-manager={field_manager} -f {} --recursive",
                style(">>>").yellow(),
                secret_dir.display(),
            );
            return Ok(());
        }
        println!(
            "{} Applying projection Secret '{secret_name}' via SSA",
            style(">>>").cyan(),
        );
        let status = crate::io::kubectl::command()
            .args([
                "--context",
                kube_context,
                "apply",
                "--server-side",
                "--force-conflicts",
                "--field-manager",
                field_manager,
                "-f",
            ])
            .arg(secret_dir)
            .arg("--recursive")
            .status()
            .context("running kubectl apply --server-side for projection Secret")?;
        if !status.success() {
            bail!("kubectl apply of projection Secret '{secret_name}' exited with {status}",);
        }
        Ok(())
    })
}

fn yaml_files_under(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for entry in fs::read_dir(dir).into_iter().flatten().flatten() {
        let path = entry.path();
        if path.is_dir() {
            out.extend(yaml_files_under(&path));
        } else if path.extension().is_some_and(|e| e == "yaml" || e == "yml") {
            out.push(path);
        }
    }
    out
}

const AWAIT_ROLLOUT: &str = "catallaxy.io/await-rollout";

fn wait_target_in_value(doc: &serde_yaml::Value) -> Option<(String, String, String)> {
    let kind = doc.get("kind")?.as_str()?.to_string();
    if !matches!(
        kind.as_str(),
        "Deployment" | "StatefulSet" | "DaemonSet" | "Job"
    ) {
        return None;
    }

    let metadata = doc.get("metadata")?;

    let opted_out = metadata
        .get("annotations")
        .and_then(|a| a.get(AWAIT_ROLLOUT))
        .is_some_and(|v| match v {
            serde_yaml::Value::Bool(b) => !*b,
            other => other.as_str() == Some("false"),
        });
    if opted_out {
        return None;
    }

    let name = metadata.get("name")?.as_str()?.to_string();
    let namespace = metadata
        .get("namespace")
        .and_then(|n| n.as_str())
        .unwrap_or("default")
        .to_string();

    Some((kind, namespace, name))
}

fn wait_targets_in_file(content: &str) -> Vec<(String, String, String)> {
    use serde::Deserialize;

    serde_yaml::Deserializer::from_str(content)
        .filter_map(|doc| serde_yaml::Value::deserialize(doc).ok())
        .filter_map(|doc| wait_target_in_value(&doc))
        .collect()
}

/// What "ready" means for a kind. A Job is never Available; it is complete or
/// it is not.
fn condition_for(kind: &str) -> &'static str {
    match kind {
        "DaemonSet" => "condition=Ready",
        "Job" => "condition=complete",
        _ => "condition=Available",
    }
}

fn wait_workloads_ready(kube_context: &str, phase_dir: &Path, timeout: &str) -> Result<()> {
    let mut targets: Vec<(String, String, String)> = Vec::new();
    for path in yaml_files_under(phase_dir) {
        let content = match fs::read_to_string(&path) {
            Ok(c) => c,
            Err(_) => continue,
        };
        targets.extend(wait_targets_in_file(&content));
    }

    if targets.is_empty() {
        return Ok(());
    }

    println!(
        "{} Waiting for {} workload(s) in {} (timeout: {timeout})",
        style(">>>").cyan(),
        targets.len(),
        phase_dir.display(),
    );
    let mut stalled: Vec<String> = Vec::new();
    for (kind, ns, name) in &targets {
        let target = format!("{}/{name}", kind.to_lowercase());
        let condition = condition_for(kind);
        let result = crate::io::kubectl::command()
            .args([
                "--context",
                kube_context,
                "-n",
                ns,
                "wait",
                &format!("--for={condition}"),
                &target,
                &format!("--timeout={timeout}"),
            ])
            .status();
        match result {
            Ok(s) if s.success() => {}
            _ => {
                println!(
                    "{} {ns}/{target} did not reach {condition} within {timeout}",
                    style("ERROR").red(),
                );
                stalled.push(format!("{ns}/{target}"));
            }
        }
    }

    if !stalled.is_empty() {
        bail!(
            "{} of {} workload(s) never became ready within {timeout}:\n  {}\n\
             `cata diagnose` shows their pods, events and logs.",
            stalled.len(),
            targets.len(),
            stalled.join("\n  "),
        );
    }
    Ok(())
}

pub fn relinquish_field_manager(
    kube_context: &str,
    manifest_root: &Path,
    field_manager: &str,
    dry_run: bool,
) -> Result<()> {
    if !manifest_root.exists() {
        return Ok(());
    }
    let files = collect_yaml_files(manifest_root);
    if files.is_empty() {
        return Ok(());
    }
    if dry_run {
        println!(
            "{} Would release '{field_manager}' field ownership across {} manifest file(s)",
            style(">>>").yellow(),
            files.len(),
        );
        return Ok(());
    }

    let mut released = 0usize;
    for file in &files {
        let out = crate::io::kubectl::command()
            .args([
                "--context",
                kube_context,
                "get",
                "-f",
                &file.display().to_string(),
                "-o",
                "json",
                "--show-managed-fields",
                "--ignore-not-found",
            ])
            .output();
        let Ok(out) = out else { continue };
        if !out.status.success() {
            continue;
        }
        let Ok(doc) = serde_json::from_slice::<serde_json::Value>(&out.stdout) else {
            continue;
        };
        let items: Vec<&serde_json::Value> = match doc.get("items").and_then(|i| i.as_array()) {
            Some(arr) => arr.iter().collect(),
            None if doc.is_object() => vec![&doc],
            _ => continue,
        };
        for item in items {
            if release_one(kube_context, item, field_manager) {
                released += 1;
            }
        }
    }
    if released > 0 {
        println!(
            "{} Released '{field_manager}' field ownership on {released} resource(s); argocd now applies uncontested",
            style(">>>").green(),
        );
    }
    Ok(())
}

fn release_one(kube_context: &str, item: &serde_json::Value, field_manager: &str) -> bool {
    let Some(kind) = item.get("kind").and_then(|k| k.as_str()) else {
        return false;
    };
    let Some(meta) = item.get("metadata") else {
        return false;
    };
    let Some(name) = meta.get("name").and_then(|n| n.as_str()) else {
        return false;
    };
    let Some(fields) = meta.get("managedFields").and_then(|f| f.as_array()) else {
        return false;
    };
    let idx = fields.iter().position(|f| {
        f.get("manager").and_then(|m| m.as_str()) == Some(field_manager)
            && f.get("operation").and_then(|o| o.as_str()) == Some("Apply")
    });
    let Some(idx) = idx else { return false };

    let patch = serde_json::json!([
        { "op": "test", "path": format!("/metadata/managedFields/{idx}/manager"), "value": field_manager },
        { "op": "remove", "path": format!("/metadata/managedFields/{idx}") },
    ])
    .to_string();

    let mut args: Vec<String> = vec![
        "--context".into(),
        kube_context.into(),
        "patch".into(),
        kind.to_ascii_lowercase(),
        name.into(),
    ];
    if let Some(ns) = meta.get("namespace").and_then(|n| n.as_str()) {
        args.push("-n".into());
        args.push(ns.into());
    }
    args.extend(["--type".into(), "json".into(), "-p".into(), patch]);

    crate::io::kubectl::command()
        .args(&args)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

fn collect_yaml_files(root: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.filter_map(|e| e.ok()) {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
            } else if path.extension().is_some_and(|e| e == "yaml" || e == "yml") {
                out.push(path);
            }
        }
    }
    out
}

fn apply_wave_bundles(
    ctx: &CataContext,
    opts: &ApplyManifests<'_>,
    wave: &Wave,
    manifest_root: &Path,
    timeout_str: &str,
) -> Result<()> {
    let &ApplyManifests {
        kube_context,
        field_manager,
        dry_run,
        ..
    } = opts;
    for bundle in &wave.bundles {
        if bundle.key.starts_with("projection/") {
            continue;
        }
        let bundle_dir = manifest_root.join(&bundle.dir);
        if !bundle_dir.exists() {
            if bundle.has_content {
                println!(
                    "{} bundle '{}' declares content but {} is missing, nothing applied",
                    style(">>>").yellow(),
                    bundle.key,
                    bundle_dir.display(),
                );
            }
            continue;
        }
        apply_bundle_with_retry(
            kube_context,
            field_manager,
            &bundle.key,
            &bundle_dir,
            dry_run,
        )?;

        wait_bundle_crds(
            ctx,
            kube_context,
            &bundle.key,
            &bundle_dir,
            timeout_str,
            dry_run,
        )?;
    }

    Ok(())
}

fn await_wave_bundles(
    ctx: &CataContext,
    opts: &ApplyManifests<'_>,
    wave: &Wave,
    manifest_root: &Path,
    timeout_str: &str,
) -> Result<()> {
    let &ApplyManifests {
        kube_context,
        dry_run,
        ..
    } = opts;
    for bundle in &wave.bundles {
        if !bundle.has_content {
            continue;
        }
        match &bundle.ready_probe {
            Some(probe) => {
                run_ready_probe(ctx, kube_context, &bundle.key, probe, timeout_str, dry_run)?
            }
            None => {
                if !dry_run {
                    wait_workloads_ready(
                        kube_context,
                        &manifest_root.join(&bundle.dir),
                        timeout_str,
                    )?;
                }
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wait_target_in_doc(doc: &str) -> Option<(String, String, String)> {
        let parsed: serde_yaml::Value = serde_yaml::from_str(doc).ok()?;
        wait_target_in_value(&parsed)
    }

    fn deployment(annotations: &str) -> String {
        format!(
            "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  annotations:{annotations}\n  labels: {{}}\n  name: netbird-agent\n  namespace: netbird\nspec:\n  replicas: 1\n"
        )
    }

    #[test]
    fn collects_an_ordinary_workload() {
        let target = wait_target_in_doc(&deployment(" {}")).expect("waited on");
        assert_eq!(
            target,
            (
                "Deployment".to_string(),
                "netbird".to_string(),
                "netbird-agent".to_string()
            )
        );
    }

    #[test]
    fn skips_a_workload_marked_await_rollout_false() {
        let doc = deployment("\n    catallaxy.io/await-rollout: \"false\"");
        assert!(wait_target_in_doc(&doc).is_none());
    }

    #[test]
    fn await_rollout_true_is_still_waited_on() {
        let doc = deployment("\n    catallaxy.io/await-rollout: \"true\"");
        assert!(wait_target_in_doc(&doc).is_some());
    }

    #[test]
    fn ignores_kinds_that_have_no_rollout() {
        let doc = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cm\n  namespace: x\n";
        assert!(wait_target_in_doc(doc).is_none());
    }

    // A bundle whose only workload is a Job used to be waited on for nothing:
    // Job was not in the list of kinds, so the next wave started immediately.
    #[test]
    fn a_job_is_a_workload() {
        let doc = "apiVersion: batch/v1\nkind: Job\nmetadata:\n  name: bootstrap-ab12\n  namespace: forgejo\n";
        assert_eq!(
            wait_target_in_doc(doc).expect("a Job is work the next wave depends on"),
            (
                "Job".to_string(),
                "forgejo".to_string(),
                "bootstrap-ab12".to_string()
            )
        );
    }

    // And it has to be waited on for the right thing. A Job never reports
    // Available, so asking for that condition would time out on a Job that
    // completed.
    #[test]
    fn a_job_is_waited_on_for_completion_not_availability() {
        assert_eq!(condition_for("Job"), "condition=complete");
        assert_eq!(condition_for("Deployment"), "condition=Available");
        assert_eq!(condition_for("DaemonSet"), "condition=Ready");
    }

    #[test]
    fn four_space_indentation_is_still_a_workload() {
        let doc = "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n    name: wide\n    namespace: team\n";
        assert_eq!(
            wait_target_in_doc(doc).expect("indentation is not the schema"),
            (
                "Deployment".to_string(),
                "team".to_string(),
                "wide".to_string()
            )
        );
    }

    #[test]
    fn the_opt_out_annotation_only_counts_on_the_workload_itself() {
        let configmap_quoting_the_annotation = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cm\ndata:\n  note: |\n    catallaxy.io/await-rollout: \"false\"\n";
        let doc = format!(
            "{configmap_quoting_the_annotation}---\n{}",
            deployment(" {}")
        );

        let targets = wait_targets_in_file(&doc);

        assert_eq!(
            targets.len(),
            1,
            "a ConfigMap that merely mentions the annotation must not disable the wait: {targets:?}"
        );
    }

    #[test]
    fn a_separator_inside_a_block_scalar_does_not_split_the_document() {
        let doc = format!(
            "apiVersion: v1\nkind: Secret\nmetadata:\n  name: tls\nstringData:\n  cert: |\n    -----BEGIN CERTIFICATE-----\n    aaa\n    ---\n    bbb\n    -----END CERTIFICATE-----\n---\n{}",
            deployment(" {}")
        );

        let targets = wait_targets_in_file(&doc);

        assert_eq!(
            targets,
            vec![(
                "Deployment".to_string(),
                "netbird".to_string(),
                "netbird-agent".to_string()
            )],
            "a --- inside a block scalar is data, not a document separator"
        );
    }

    #[test]
    fn an_unquoted_false_opts_out_too() {
        let doc = deployment("\n    catallaxy.io/await-rollout: false");
        assert!(wait_target_in_doc(&doc).is_none());
    }
}

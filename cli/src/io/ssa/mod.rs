use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::path::{Path, PathBuf};
use std::thread::sleep;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use console::style;

use crate::apply::{
    ProjectionConfig, ProjectionSource, inject_projections_with, parse_projections,
};
use crate::config::Context as CataContext;
use crate::domain::SecretsCache;
use crate::domain::prune::{PruneInputs, ResourceKey, plan_prune};
use crate::domain::{ClusterSpec, SecretsSpec};
use crate::io;

mod probe;

pub use probe::ReadyProbe;
use probe::run_ready_probe;

/// How long to keep re-applying a bundle that will not take yet.
///
/// A bundle can contain both an admission webhook and the objects that webhook
/// validates: kube-prometheus-stack ships its operator, the
/// `MutatingWebhookConfiguration` pointing at it, and the PrometheusRules it
/// checks, all in one Helm release. `kubectl apply` sends them together, so the
/// rules are rejected until the operator has an endpoint, and retrying is the
/// only thing that can succeed.
///
/// This used to be four attempts, which with the backoff below is eighteen
/// seconds of waiting. That is shorter than a cold image pull, so whether it
/// worked came down to how much else had already been installed: prometheus
/// passed only because an unrelated edge happened to place it late. Deleting
/// that edge, correctly, made it fail. A deadline says what the retry is
/// actually for, and does not depend on where in the plan the bundle lands.
const BUNDLE_APPLY_DEADLINE: Duration = Duration::from_secs(180);
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

/// Server-side apply every manifest under `manifest_root`, in phase order,
/// then wait for the workloads it created.
///
/// # Errors
///
/// If the kube context is empty, if `manifest_root` does not exist, if a phase
/// still fails after its retries, or if a workload never becomes ready within
/// `wait_timeout_seconds`. A missing manifest root is an error rather than an
/// empty apply, because it means the lab package was not built.
pub fn apply_manifest_root(ctx: &CataContext, opts: ApplyManifests<'_>) -> Result<()> {
    let ApplyManifests {
        manifest_root,
        wait_timeout_seconds,
        ..
    } = opts;
    crate::io::kube_context::require_named(opts.kube_context)?;

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

    prune_undeclared(opts, &meta, manifest_root)
}

/// Delete what the declaration stopped naming.
///
/// Runs after every wave, not per wave: a resource can move between bundles,
/// and pruning mid-apply would delete it before the bundle that now owns it
/// had a chance to apply it.
fn prune_undeclared(
    opts: &ApplyManifests<'_>,
    meta: &WaveMeta,
    manifest_root: &Path,
) -> Result<()> {
    let &ApplyManifests {
        kube_context,
        dry_run,
        lab_name,
        ..
    } = opts;

    // No file means a tree rendered before pruning existed. Deleting on that
    // basis would treat every bundle as undeclared, so say nothing and do
    // nothing.
    let Some(declared) = declared_bundles(manifest_root) else {
        return Ok(());
    };

    let applied_bundles: BTreeSet<String> = meta
        .waves
        .iter()
        .flat_map(|w| w.bundles.iter().map(|b| b.key.clone()))
        .collect();

    let kubectl = io::kubectl::seam::Real;
    let live = io::kubectl::owned::owned_by_lab(&kubectl, kube_context, lab_name)?;
    let plan = plan_prune(PruneInputs {
        live: &live,
        declared_bundles: &declared,
        applied_bundles: &applied_bundles,
        applied: &applied_resources(manifest_root),
    });

    if plan.is_empty() {
        return Ok(());
    }

    for key in &plan.delete {
        if dry_run {
            println!(
                "{} Would remove {}, which the lab no longer declares",
                style(">>>").yellow(),
                key.describe(),
            );
            continue;
        }
        println!(
            "{} Removing {}, which the lab no longer declares",
            style(">>>").cyan(),
            key.describe(),
        );
        io::kubectl::owned::delete(&kubectl, kube_context, key)?;
    }

    if !plan.orphaned_storage.is_empty() {
        println!();
        println!(
            "{} The lab no longer declares these, and they hold data, so they \
             were left alone:",
            style("note:").yellow(),
        );
        for key in &plan.orphaned_storage {
            println!("      {}", key.describe());
        }
        println!(
            "      A lab that comes back finds its data. Remove them with \
             `kubectl delete` when you are sure."
        );
    }

    if !plan.unattributed.is_empty() {
        println!();
        println!(
            "{} These carry this lab's label but name no bundle, so nothing \
             can say whether the lab still wants them:",
            style("note:").yellow(),
        );
        for key in &plan.unattributed {
            println!("      {}", key.describe());
        }
    }

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
    let started = Instant::now();
    let mut attempt = 0u32;
    loop {
        attempt += 1;
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
        if started.elapsed() + PHASE_APPLY_BACKOFF >= BUNDLE_APPLY_DEADLINE {
            bail!(
                "kubectl apply of bundle '{bundle_key}' failed after {attempt} attempts over \
                 {elapsed}s: kubectl apply exited with {status}",
                elapsed = started.elapsed().as_secs(),
            );
        }
        println!(
            "{} kubectl apply of bundle '{bundle_key}' failed (attempt {attempt}, {elapsed}s of \
             {deadline}s); sleeping {backoff}s and retrying.",
            style(">>>").yellow(),
            elapsed = started.elapsed().as_secs(),
            deadline = BUNDLE_APPLY_DEADLINE.as_secs(),
            backoff = PHASE_APPLY_BACKOFF.as_secs(),
        );
        sleep(PHASE_APPLY_BACKOFF);
    }
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

/// Every resource the applied tree declares, as the cluster would name it.
fn applied_resources(manifest_root: &Path) -> BTreeSet<ResourceKey> {
    let mut out = BTreeSet::new();
    for path in yaml_files_under(manifest_root) {
        let Ok(content) = fs::read_to_string(&path) else {
            continue;
        };
        for doc in serde_yaml::Deserializer::from_str(&content) {
            let Ok(value) = <serde_yaml::Value as serde::Deserialize>::deserialize(doc) else {
                continue;
            };
            let (Some(kind), Some(metadata)) = (
                value.get("kind").and_then(|k| k.as_str()),
                value.get("metadata"),
            ) else {
                continue;
            };
            let Some(name) = metadata.get("name").and_then(|n| n.as_str()) else {
                continue;
            };
            out.insert(ResourceKey::new(
                kind,
                metadata.get("namespace").and_then(|n| n.as_str()),
                name,
            ));
        }
    }
    out
}

/// Bundles the cluster declares, whoever applies them.
///
/// Written by the renderer because only the declaration knows it. The applied
/// tree is a subset -- for an argocd lab, just the install-target set -- so it
/// cannot tell a bundle that was dropped from one argocd owns.
fn declared_bundles(manifest_root: &Path) -> Option<BTreeSet<String>> {
    let raw = fs::read_to_string(manifest_root.join(".declared-bundles")).ok()?;
    Some(
        raw.lines()
            .map(str::trim)
            .filter(|l| !l.is_empty())
            .map(String::from)
            .collect(),
    )
}

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

/// How to ask Kubernetes whether a workload is up.
///
/// Only Deployments carry an `Available` condition and only Jobs carry
/// `complete`; StatefulSets and DaemonSets carry neither, so a condition wait
/// on those blocks until the timeout however healthy they are.
enum Readiness {
    Rollout,
    Condition(&'static str),
}

fn readiness_for(kind: &str) -> Readiness {
    match kind {
        "Job" => Readiness::Condition("condition=complete"),
        _ => Readiness::Rollout,
    }
}

/// How many replicas a workload wants, when it can say.
fn desired_replicas(kube_context: &str, ns: &str, target: &str) -> Option<String> {
    let out = crate::io::process::run_capture(
        crate::io::kubectl::command()
            .args(["--context", kube_context, "-n", ns])
            .args(["get", target, "-o", "jsonpath={.spec.replicas}"]),
    )
    .ok()?;
    let n = out.trim().to_string();
    if n.is_empty() { None } else { Some(n) }
}

/// Whether this workload updates on delete rather than by rolling.
///
/// `kubectl rollout status` refuses outright on any strategy but
/// RollingUpdate, so asking it about one of these reports a healthy workload
/// as never having rolled out. openbao's StatefulSet is OnDelete, and its pod
/// was Running and Ready while the deploy failed on it.
fn updates_on_delete(kube_context: &str, ns: &str, target: &str) -> bool {
    crate::io::process::run_capture(
        crate::io::kubectl::command()
            .args(["--context", kube_context, "-n", ns])
            .args(["get", target, "-o", "jsonpath={.spec.updateStrategy.type}"]),
    )
    .map(|o| o.trim() == "OnDelete")
    .unwrap_or(false)
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
        let (args, what): (Vec<String>, String) = match readiness_for(kind) {
            Readiness::Rollout if updates_on_delete(kube_context, ns, &target) => {
                let want =
                    desired_replicas(kube_context, ns, &target).unwrap_or_else(|| "1".into());
                (
                    vec![
                        "wait".to_string(),
                        format!("--for=jsonpath={{.status.readyReplicas}}={want}"),
                        target.clone(),
                        format!("--timeout={timeout}"),
                    ],
                    format!("have {want} ready replica(s)"),
                )
            }
            Readiness::Rollout => (
                vec![
                    "rollout".to_string(),
                    "status".to_string(),
                    target.clone(),
                    format!("--timeout={timeout}"),
                ],
                "finish rolling out".to_string(),
            ),
            Readiness::Condition(condition) => (
                vec![
                    "wait".to_string(),
                    format!("--for={condition}"),
                    target.clone(),
                    format!("--timeout={timeout}"),
                ],
                format!("reach {condition}"),
            ),
        };
        let result = crate::io::kubectl::command()
            .args(["--context", kube_context, "-n", ns])
            .args(&args)
            .status();
        match result {
            Ok(s) if s.success() => {}
            _ => {
                println!(
                    "{} {ns}/{target} did not {what} within {timeout}",
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

/// Drop this field manager's ownership of the fields it applied, so a later
/// owner takes them without a conflict.
///
/// # Errors
///
/// Never. A manifest that cannot be read, and a release that fails, are both
/// skipped: the caller's next step is argocd taking over, and a field still
/// owned makes that a conflict argocd reports, not a reason to fail here. The
/// count actually released is printed.
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
        // Workloads first, then the probe, and never one instead of the
        // other. A probe says "this bundle's own thing is working" -- an
        // Issuer answers, a CR reports Ready -- which is a narrower question
        // than "every Deployment I shipped is Available". Treating the probe
        // as a replacement let the next wave start against a bundle whose
        // pods were still coming up, which is how a webhook-owning bundle
        // like cert-manager races the resources that need its webhook.
        //
        // A bundle with no workloads makes the wait a no-op, so this costs
        // nothing where the probe was genuinely the only signal available.
        if !dry_run {
            wait_workloads_ready(kube_context, &manifest_root.join(&bundle.dir), timeout_str)?;
        }
        if let Some(probe) = &bundle.ready_probe {
            run_ready_probe(ctx, kube_context, &bundle.key, probe, timeout_str, dry_run)?;
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

    // Only Deployments have an Available condition and only Jobs have
    // complete. Waiting on a condition a kind never reports blocks until the
    // timeout no matter how healthy the workload is, which is what a
    // StatefulSet did for ten minutes before failing a deploy.
    #[test]
    fn the_controllers_are_asked_about_their_rollout_not_a_condition() {
        for kind in ["Deployment", "StatefulSet", "DaemonSet"] {
            assert!(
                matches!(readiness_for(kind), Readiness::Rollout),
                "{kind} should be waited on with `rollout status`"
            );
        }
    }

    #[test]
    fn a_job_is_asked_whether_it_completed() {
        assert!(matches!(
            readiness_for("Job"),
            Readiness::Condition("condition=complete")
        ));
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

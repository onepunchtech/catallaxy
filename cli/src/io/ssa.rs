use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread::sleep;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use console::style;

use crate::commands::apply::SecretsCache;
use crate::commands::apply::{ProjectionConfig, inject_projections_with, parse_projections};
use crate::config::Context as CataContext;
use crate::io;

const BUNDLE_APPLY_ATTEMPTS: u32 = 4;
const PHASE_APPLY_BACKOFF: Duration = Duration::from_secs(6);

pub fn apply_manifest_root(
    ctx: &CataContext,
    kube_context: &str,
    manifest_root: &Path,
    field_manager: &str,
    wait_timeout_seconds: u64,
    dry_run: bool,
    lab_config: Option<&serde_json::Value>,
    secrets_cache: Option<&SecretsCache>,
) -> Result<()> {
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
    apply_wave_ordered(
        ctx,
        kube_context,
        manifest_root,
        &wave_meta_path,
        field_manager,
        &timeout_str,
        dry_run,
        lab_config,
        secrets_cache,
    )
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
    #[serde(default)]
    #[allow(dead_code)]
    requires: Vec<String>,
    #[serde(default)]
    #[allow(dead_code)]
    provides: Vec<String>,
    pub has_content: bool,
}

#[derive(serde::Deserialize, Debug)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum ReadyProbe {
    Condition {
        resource: String,
        #[serde(default)]
        namespace: Option<String>,
        condition: String,
        #[serde(default)]
        timeout: Option<String>,
    },
    Jsonpath {
        resource: String,
        #[serde(default)]
        namespace: Option<String>,
        jsonpath: String,
        #[serde(default)]
        value: Option<serde_json::Value>,
        #[serde(default)]
        timeout: Option<String>,
    },
    Exists {
        resource: String,
        #[serde(default)]
        namespace: Option<String>,
        #[serde(default)]
        timeout: Option<String>,
    },
    Pod {
        image: String,
        command: Vec<String>,
        #[serde(default)]
        args: Vec<String>,
        #[serde(default)]
        namespace: Option<String>,
        #[serde(default)]
        timeout: Option<String>,
    },
    #[serde(rename = "kubectl-wait")]
    KubectlWait {
        args: Vec<String>,
    },
    Script {
        body: String,
    },
}

impl ReadyProbe {
    pub fn target(&self) -> Option<&str> {
        match self {
            ReadyProbe::Condition { resource, .. }
            | ReadyProbe::Jsonpath { resource, .. }
            | ReadyProbe::Exists { resource, .. } => Some(resource),
            _ => None,
        }
    }
}

fn apply_wave_ordered(
    ctx: &CataContext,
    kube_context: &str,
    manifest_root: &Path,
    wave_meta_path: &Path,
    field_manager: &str,
    timeout_str: &str,
    dry_run: bool,
    lab_config: Option<&serde_json::Value>,
    secrets_cache: Option<&SecretsCache>,
) -> Result<()> {
    let raw = fs::read_to_string(wave_meta_path)
        .with_context(|| format!("reading .wave-meta at {}", wave_meta_path.display()))?;
    let meta: WaveMeta = serde_json::from_str(&raw)
        .with_context(|| format!("parsing .wave-meta at {}", wave_meta_path.display()))?;

    let projections: HashMap<String, ProjectionConfig> =
        lab_config.map(parse_projections).unwrap_or_default();

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
            if let Some(cfg) = lab_config {
                inject_projections_ssa(
                    ctx,
                    kube_context,
                    cfg,
                    &wave_projections,
                    field_manager,
                    secrets_cache.map(|v| &**v),
                    dry_run,
                )?;
            }
        }

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
        let status = Command::new("kubectl")
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
    ctx: &CataContext,
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
        io::kubectl::wait_crd_established(ctx, kube_context, crd, timeout)?;
    }
    Ok(())
}

fn run_ready_probe(
    ctx: &CataContext,
    kube_context: &str,
    bundle_key: &str,
    probe: &ReadyProbe,
    fallback_timeout: &str,
    dry_run: bool,
) -> Result<()> {
    match probe {
        ReadyProbe::Condition {
            resource,
            namespace,
            condition,
            timeout,
        } => {
            let timeout = timeout.as_deref().unwrap_or(fallback_timeout);
            let ns_args: Vec<String> = match namespace {
                Some(ns) => vec!["-n".into(), ns.clone()],
                None => vec![],
            };
            let mk_args = |for_arg: String| -> Vec<String> {
                let mut a: Vec<String> = vec!["--context".into(), kube_context.into()];
                a.extend(ns_args.iter().cloned());
                a.push("wait".into());
                a.push(for_arg);
                a.push(resource.clone());
                a.push(format!("--timeout={timeout}"));
                a
            };
            let create_args = mk_args("--for=create".into());
            let (res_kind, _res_name) = resource.split_once('/').unwrap_or((resource.as_str(), ""));
            let cond_for_arg = if condition.eq_ignore_ascii_case("Available") {
                match res_kind.to_ascii_lowercase().as_str() {
                    "statefulset" | "sts" | "statefulsets" => {
                        "--for=jsonpath={.status.readyReplicas}=1".into()
                    }
                    "daemonset" | "ds" | "daemonsets" => {
                        "--for=jsonpath={.status.numberReady}=1".into()
                    }
                    _ => format!("--for=condition={condition}"),
                }
            } else {
                format!("--for=condition={condition}")
            };
            let cond_args = mk_args(cond_for_arg);
            if dry_run {
                println!(
                    "{} Would kubectl {} then kubectl {} (readyProbe for '{bundle_key}')",
                    style(">>>").yellow(),
                    create_args.join(" "),
                    cond_args.join(" "),
                );
                return Ok(());
            }
            println!(
                "{} Waiting on readyProbe for '{bundle_key}' → {resource} condition={condition}",
                style(">>>").cyan(),
            );
            let create_status = Command::new("kubectl")
                .args(&create_args)
                .status()
                .context("running kubectl wait --for=create for readyProbe")?;
            if !create_status.success() {
                bail!(
                    "readyProbe for '{bundle_key}' ({resource}) never appeared within {timeout}: {create_status}"
                );
            }
            let cond_status = Command::new("kubectl")
                .args(&cond_args)
                .status()
                .context("running kubectl wait for readyProbe condition")?;
            if !cond_status.success() {
                bail!(
                    "readyProbe for '{bundle_key}' ({resource} condition={condition}) failed: {cond_status}"
                );
            }
            Ok(())
        }
        ReadyProbe::Jsonpath {
            resource,
            namespace,
            jsonpath,
            value,
            timeout,
        } => {
            let timeout = timeout.as_deref().unwrap_or(fallback_timeout);
            let mk_args = |for_arg: String| -> Vec<String> {
                let mut a: Vec<String> = vec!["--context".into(), kube_context.into()];
                if let Some(ns) = namespace {
                    a.push("-n".into());
                    a.push(ns.clone());
                }
                a.push("wait".into());
                a.push(for_arg);
                a.push(resource.clone());
                a.push(format!("--timeout={timeout}"));
                a
            };
            let create_args = mk_args("--for=create".into());
            let suffix = match value {
                Some(serde_json::Value::String(s)) => format!("={s}"),
                Some(v) => format!("={v}"),
                None => String::new(),
            };
            let path_args = mk_args(format!("--for=jsonpath={jsonpath}{suffix}"));
            if dry_run {
                println!(
                    "{} Would kubectl {} then kubectl {} (readyProbe for '{bundle_key}')",
                    style(">>>").yellow(),
                    create_args.join(" "),
                    path_args.join(" "),
                );
                return Ok(());
            }
            println!(
                "{} Waiting on readyProbe for '{bundle_key}' → {resource} jsonpath={jsonpath}{suffix}",
                style(">>>").cyan(),
            );
            let create_status = Command::new("kubectl")
                .args(&create_args)
                .status()
                .context("running kubectl wait --for=create for readyProbe")?;
            if !create_status.success() {
                bail!(
                    "readyProbe for '{bundle_key}' ({resource}) never appeared within {timeout}: {create_status}"
                );
            }
            let path_status = Command::new("kubectl")
                .args(&path_args)
                .status()
                .context("running kubectl wait --for=jsonpath for readyProbe")?;
            if !path_status.success() {
                bail!(
                    "readyProbe for '{bundle_key}' ({resource} jsonpath={jsonpath}{suffix}) failed: {path_status}"
                );
            }
            Ok(())
        }
        ReadyProbe::Exists {
            resource,
            namespace,
            timeout,
        } => {
            let timeout = timeout.as_deref().unwrap_or(fallback_timeout);
            let mut args: Vec<String> = vec!["--context".into(), kube_context.into()];
            if let Some(ns) = namespace {
                args.push("-n".into());
                args.push(ns.clone());
            }
            args.push("wait".into());
            args.push("--for=create".into());
            args.push(resource.clone());
            args.push(format!("--timeout={timeout}"));
            if dry_run {
                println!(
                    "{} Would kubectl {} (readyProbe for '{bundle_key}')",
                    style(">>>").yellow(),
                    args.join(" "),
                );
                return Ok(());
            }
            println!(
                "{} Waiting on readyProbe for '{bundle_key}' → {resource} exists",
                style(">>>").cyan(),
            );
            let status = Command::new("kubectl")
                .args(&args)
                .status()
                .context("running kubectl wait --for=create for readyProbe")?;
            if !status.success() {
                bail!(
                    "readyProbe for '{bundle_key}' ({resource}) never appeared within {timeout}: {status}"
                );
            }
            Ok(())
        }
        ReadyProbe::Pod {
            image,
            command,
            args,
            namespace,
            timeout,
        } => {
            let timeout = timeout.as_deref().unwrap_or(fallback_timeout);
            let ns = namespace.as_deref().unwrap_or("default");
            let slug: String = bundle_key
                .chars()
                .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
                .collect::<String>()
                .trim_matches('-')
                .to_ascii_lowercase();
            let stamp = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            let truncated: String = slug.chars().take(40).collect();
            let pod_name = format!("probe-{}-{stamp}", truncated.trim_matches('-'));

            let mut full: Vec<String> = vec![
                "--context".into(),
                kube_context.into(),
                "-n".into(),
                ns.into(),
                "run".into(),
                pod_name.clone(),
                "--rm".into(),
                "--attach".into(),
                "--restart=Never".into(),
                format!("--pod-running-timeout={timeout}"),
                format!("--image={image}"),
                "--command".into(),
                "--".into(),
            ];
            full.extend(command.iter().cloned());
            full.extend(args.iter().cloned());
            if dry_run {
                println!(
                    "{} Would kubectl {} (readyProbe for '{bundle_key}')",
                    style(">>>").yellow(),
                    full.join(" "),
                );
                return Ok(());
            }
            println!(
                "{} Waiting on readyProbe for '{bundle_key}' → in-cluster probe Pod {ns}/{pod_name} ({image})",
                style(">>>").cyan(),
            );
            let status = Command::new("kubectl")
                .args(&full)
                .status()
                .context("running kubectl run for readyProbe probe Pod")?;
            if !status.success() {
                bail!("readyProbe for '{bundle_key}' (probe Pod {ns}/{pod_name}) failed: {status}");
            }
            Ok(())
        }
        ReadyProbe::KubectlWait { args } => {
            let mut full: Vec<String> =
                vec!["--context".into(), kube_context.into(), "wait".into()];
            full.extend(args.iter().cloned());
            if dry_run {
                println!(
                    "{} Would kubectl {} (readyProbe for '{bundle_key}')",
                    style(">>>").yellow(),
                    full.join(" "),
                );
                return Ok(());
            }
            println!(
                "{} Waiting on readyProbe for '{bundle_key}' → kubectl-wait {}",
                style(">>>").cyan(),
                args.join(" "),
            );
            let status = Command::new("kubectl")
                .args(&full)
                .status()
                .context("running kubectl wait for readyProbe")?;
            if !status.success() {
                bail!("readyProbe for '{bundle_key}' (kubectl-wait) failed: {status}");
            }
            Ok(())
        }
        ReadyProbe::Script { body } => {
            if dry_run {
                println!(
                    "{} Would run readyProbe script for '{bundle_key}' ({} bytes)",
                    style(">>>").yellow(),
                    body.len(),
                );
                return Ok(());
            }
            println!(
                "{} Running readyProbe script for '{bundle_key}'",
                style(">>>").cyan(),
            );
            let _ = ctx;
            let status = Command::new("bash")
                .args(["-euo", "pipefail", "-c", body])
                .env("KUBE_CONTEXT", kube_context)
                .status()
                .context("running readyProbe script")?;
            if !status.success() {
                bail!("readyProbe script for '{bundle_key}' failed: {status}");
            }
            Ok(())
        }
    }
}

fn inject_projections_ssa(
    ctx: &CataContext,
    kube_context: &str,
    lab_config: &serde_json::Value,
    projections: &[(String, ProjectionConfig)],
    field_manager: &str,
    pre_cache: Option<&HashMap<String, HashMap<String, HashMap<String, String>>>>,
    dry_run: bool,
) -> Result<()> {
    inject_projections_with(
        ctx,
        kube_context,
        lab_config,
        projections,
        pre_cache,
        |secret_dir, secret_name| {
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
            let status = Command::new("kubectl")
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
        },
    )
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

fn wait_target_in_doc(doc: &str) -> Option<(String, String, String)> {
    if doc.contains("catallaxy.io/await-rollout: \"false\"")
        || doc.contains("catallaxy.io/await-rollout: 'false'")
        || doc.contains("catallaxy.io/await-rollout: false")
    {
        return None;
    }
    let mut kind = None;
    let mut name = None;
    let mut ns = None;
    let mut in_metadata = false;
    for line in doc.lines() {
        let trimmed = line.trim_start();
        if line.starts_with("kind:") {
            kind = Some(line["kind:".len()..].trim().to_string());
        } else if line.starts_with("metadata:") {
            in_metadata = true;
        } else if in_metadata && trimmed.starts_with("name:") && !line.starts_with(' ') {
            name = Some(trimmed["name:".len()..].trim().to_string());
        } else if in_metadata && line.starts_with("  name:") && name.is_none() {
            name = Some(line["  name:".len()..].trim().trim_matches('"').to_string());
        } else if in_metadata && line.starts_with("  namespace:") && ns.is_none() {
            ns = Some(
                line["  namespace:".len()..]
                    .trim()
                    .trim_matches('"')
                    .to_string(),
            );
        } else if !line.starts_with(' ')
            && !line.is_empty()
            && !line.starts_with("apiVersion")
            && !line.starts_with("kind")
        {
            in_metadata = false;
        }
    }
    let (k, n) = (kind?, name?);
    if matches!(k.as_str(), "Deployment" | "StatefulSet" | "DaemonSet") {
        Some((k, ns.unwrap_or_else(|| "default".to_string()), n))
    } else {
        None
    }
}

fn wait_workloads_ready(kube_context: &str, phase_dir: &Path, timeout: &str) -> Result<()> {
    let mut targets: Vec<(String, String, String)> = Vec::new();
    for path in yaml_files_under(phase_dir) {
        let content = match fs::read_to_string(&path) {
            Ok(c) => c,
            Err(_) => continue,
        };
        targets.extend(content.split("\n---").filter_map(wait_target_in_doc));
    }

    if targets.is_empty() {
        return Ok(());
    }

    println!(
        "{} Waiting for {} workload(s) in {} to be Available (timeout: {timeout})",
        style(">>>").cyan(),
        targets.len(),
        phase_dir.display(),
    );
    for (kind, ns, name) in &targets {
        let target = format!("{}/{name}", kind.to_lowercase());
        let condition = match kind.as_str() {
            "DaemonSet" => "condition=Ready",
            _ => "condition=Available",
        };
        let result = Command::new("kubectl")
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
                    "{} {ns}/{target} did not reach {condition} within {timeout} \
                     (continuing)",
                    style(">>>").yellow(),
                );
            }
        }
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
        let out = Command::new("kubectl")
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

    Command::new("kubectl")
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

#[cfg(test)]
mod tests {
    use super::*;

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
}

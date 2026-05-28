//! Apply manifests to a cluster
//!
//! Discovers phases from rendered manifest directories and deploys them
//! sequentially or in parallel via kapp.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use clap::Args;
use console::style;
use serde::Deserialize;

use crate::commands::secrets as secrets_mod;
use crate::config::Context as CataContext;
use crate::{nix, tools};

#[derive(Args)]
pub struct ApplyArgs {
    /// Cluster name (defaults to flake fragment if provided)
    pub cluster: Option<String>,

    /// Apply only a specific phase
    #[arg(long)]
    pub phase: Option<String>,

    /// Apply only a specific component (within its phase)
    #[arg(long)]
    pub component: Option<String>,

    /// Dry run (don't actually apply)
    #[arg(long)]
    pub dry_run: bool,

    /// Deploy phases sequentially instead of in parallel
    #[arg(long)]
    pub sequential: bool,

    /// Force direct apply even when the lab uses a GitOps strategy (argocd/fleet)
    #[arg(long)]
    pub force: bool,

    /// Pre-built manifests directory (skip nix build).
    /// Used by lab commands that build the lab package once for all clusters.
    #[arg(skip)]
    pub manifests_dir: Option<String>,
}

/// A phase discovered from rendered manifest output
#[derive(Debug, Clone)]
struct Phase {
    name: String,
    dir: PathBuf,
    order: usize,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProjectionConfig {
    source: String,
    namespace: String,
    phase: String,
    keys: HashMap<String, ProjectionKeyConfig>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProjectionKeyConfig {
    from: String,
    transform: Option<String>,
    json_key: Option<String>,
}

/// Parse projections from cluster config, grouped by phase.
fn parse_projections(
    config: &serde_json::Value,
) -> HashMap<String, Vec<(String, ProjectionConfig)>> {
    let mut by_phase: HashMap<String, Vec<(String, ProjectionConfig)>> = HashMap::new();

    let projs_value = match config.get("projections") {
        Some(v) => v,
        None => return by_phase,
    };

    let projs: HashMap<String, ProjectionConfig> =
        match serde_json::from_value(projs_value.clone()) {
            Ok(p) => p,
            Err(_) => return by_phase,
        };

    for (name, proj) in projs {
        let phase = proj.phase.clone();
        by_phase.entry(phase).or_default().push((name, proj));
    }

    by_phase
}

pub async fn run(ctx: &CataContext, args: ApplyArgs) -> Result<()> {
    let cluster = ctx.resolve_cluster_name(args.cluster.as_deref())?;

    println!(
        "{} Applying to cluster '{cluster}'",
        style("catallaxy").cyan().bold(),
    );
    println!();

    // Get cluster config (needed for kube context resolution and secrets)
    let config = nix::get_cluster_config(ctx, &cluster)?;
    let strategy = config
        .pointer("/deploy/strategy")
        .and_then(|v| v.as_str())
        .unwrap_or("kapp");

    if (strategy == "argocd" || strategy == "fleet") && !args.force {
        bail!(
            "This lab uses '{strategy}' strategy — manifests must be deployed via Git.\n\
             Use 'cata lab publish' to push manifests to the Git repository.\n\
             To apply directly anyway, use --force."
        );
    }

    // Resolve kube context
    let kube_context = resolve_kube_context(&config, &cluster);

    // Build rendered manifests (skip if pre-built path was provided)
    let manifests_path = if let Some(ref dir) = args.manifests_dir {
        println!("{} Using pre-built manifests: {dir}", style(">>>").green());
        dir.clone()
    } else {
        println!("{} Building manifests...", style(">>>").cyan());
        let path = nix::build_manifests(ctx, &cluster)?;
        println!("{} Manifests built: {path}", style(">>>").green());
        path
    };

    // Manifests may be nested under a cluster subdirectory (e.g., kapp-mgmt/mgmt/)
    let cluster_subdir = Path::new(&manifests_path).join(&cluster);
    let effective_path = if cluster_subdir.is_dir() {
        cluster_subdir.display().to_string()
    } else {
        manifests_path.clone()
    };

    match strategy {
        "kapp" => apply_kapp(ctx, &kube_context, &effective_path, &args, &config).await,
        "argocd" => apply_gitops(ctx, "argocd", &effective_path, &config).await,
        "fleet" => apply_gitops(ctx, "fleet", &effective_path, &config).await,
        _ => bail!("Unknown deploy strategy: {strategy}"),
    }
}

/// Resolve the kubectl context name for a cluster
fn resolve_kube_context(config: &serde_json::Value, cluster: &str) -> String {
    let is_k3d = config["provisioner"].as_str().unwrap_or("k3d") == "k3d";

    if is_k3d {
        let default_name = format!("catallaxy-{cluster}");
        let k3d_name = config
            .pointer("/provisionerConfig/k3d/clusterName")
            .and_then(|v| v.as_str())
            .unwrap_or(&default_name);
        format!("k3d-{k3d_name}")
    } else {
        let provisioner = config["provisioner"].as_str().unwrap_or("k3d");
        match provisioner {
            "talos" => format!("{cluster}-admin@{cluster}"),
            _ => cluster.to_string(),
        }
    }
}

/// Discover phases from the rendered manifest directory.
///
/// Reads `.phase-order` for the ordered phase names, then maps each to its
/// numbered directory (e.g., `00-crds/`, `01-namespaces/`).
fn discover_phases(cluster_manifests: &Path) -> Result<Vec<Phase>> {
    let phase_order_file = cluster_manifests.join(".phase-order");
    let content = fs::read_to_string(&phase_order_file)
        .with_context(|| format!("reading {}", phase_order_file.display()))?;

    let phase_names: Vec<String> = content
        .lines()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty())
        .collect();

    // Build map of phase name → directory by scanning numbered dirs
    let mut dir_map: HashMap<String, PathBuf> = HashMap::new();
    for entry in fs::read_dir(cluster_manifests)? {
        let entry = entry?;
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let dir_name = entry.file_name().to_string_lossy().to_string();
        // Directories are named "NN-phasename" (e.g., "00-crds", "01-namespaces")
        if let Some(phase_name) = dir_name.split_once('-').map(|(_, name)| name.to_string()) {
            dir_map.insert(phase_name, path);
        }
    }

    let mut phases = Vec::new();
    for (i, name) in phase_names.iter().enumerate() {
        if let Some(dir) = dir_map.get(name) {
            phases.push(Phase {
                name: name.clone(),
                dir: dir.clone(),
                order: i,
            });
        }
    }

    Ok(phases)
}

/// Read deploy config (timeout, etc.) from `.deploy-config`
fn read_deploy_timeout(cluster_manifests: &Path) -> String {
    let config_file = cluster_manifests.join(".deploy-config");
    if let Ok(content) = fs::read_to_string(&config_file) {
        for line in content.lines() {
            let trimmed = line.trim();
            if let Some(val) = trimmed.strip_prefix("waitTimeout:") {
                return val.trim().to_string();
            }
        }
    }
    "10m".to_string()
}

/// Deploy manifests directly via kapp
async fn apply_kapp(
    ctx: &CataContext,
    kube_context: &str,
    manifests_path: &str,
    args: &ApplyArgs,
    config: &serde_json::Value,
) -> Result<()> {
    if !tools::kube::api_reachable(kube_context) {
        bail!("Cannot reach cluster (context: {kube_context}). Is it running?");
    }

    let cluster_manifests = Path::new(manifests_path);
    let mut phases = discover_phases(cluster_manifests)?;
    let timeout = read_deploy_timeout(cluster_manifests);

    // Filter to specific phase if requested
    if let Some(ref phase_name) = args.phase {
        phases.retain(|p| p.name == *phase_name);
        if phases.is_empty() {
            bail!("Phase '{phase_name}' not found in rendered manifests");
        }
    }

    // Parse projections for secret injection
    let sops_secrets = parse_projections(config);
    let cluster_name = ctx.resolve_cluster_name(args.cluster.as_deref())?;

    if args.dry_run {
        println!("{} Dry run — would deploy:", style("Note:").yellow());
        for phase in &phases {
            let has_sops = sops_secrets
                .get(&phase.name)
                .map_or(false, |s| !s.is_empty());
            let sops_note = if has_sops { " + secrets" } else { "" };
            println!(
                "  {} {} (order: {}){}",
                style("phase:").dim(),
                style(&phase.name).bold(),
                phase.order,
                sops_note,
            );
        }
        return Ok(());
    }

    // Clean up k3s auto-deployed bootstrap resources before kapp applies.
    // k3s auto-deploy mounts Cilium at boot so nodes get CNI immediately, but kapp
    // can't adopt these Deployments (immutable spec.selector label conflict).
    // Deleting them lets kapp recreate them with proper ownership.
    cleanup_bootstrap_resources(kube_context, config);

    // Deploy phases sequentially (dependency ordering is already encoded in phase order)
    for phase in &phases {
        println!(
            "\n{} Phase: {} (order: {})",
            style(">>>").cyan(),
            style(&phase.name).bold(),
            phase.order,
        );

        // Wait for CRDs if this phase requires them
        let crd_wait_file = phase.dir.join(".crd-wait");
        if crd_wait_file.exists() {
            if let Ok(content) = fs::read_to_string(&crd_wait_file) {
                for crd in content.lines().map(|l| l.trim()).filter(|l| !l.is_empty()) {
                    println!("{} Waiting for CRD: {crd}...", style(">>>").cyan());
                    tools::kube::wait_crd_established(ctx, kube_context, crd, &timeout)?;
                }
            }
        }

        // Inject projected secrets before deploying phase
        if let Some(projections) = sops_secrets.get(&phase.name) {
            inject_projections(ctx, kube_context, &cluster_name, config, projections, &timeout)?;
        }

        println!(
            "{} Deploying {}...",
            style(">>>").cyan(),
            style(&phase.name).bold(),
        );
        tools::kapp::deploy(
            ctx,
            kube_context,
            &phase.name,
            &phase.dir.display().to_string(),
            &timeout,
        )?;
    }

    println!();
    println!("{} All phases deployed", style(">>>").green());

    Ok(())
}

/// Inject projected secrets for a phase via kapp.
///
/// Resolves: projection → managed secret → store → SOPS file → transforms → K8s Secret
fn inject_projections(
    ctx: &CataContext,
    kube_context: &str,
    _cluster_name: &str,
    config: &serde_json::Value,
    projections: &[(String, ProjectionConfig)],
    timeout: &str,
) -> Result<()> {
    // Get lab name from config to find SOPS files
    let lab_name = config
        .pointer("/labName")
        .or_else(|| config.pointer("/outputs/labName"))
        .and_then(|v| v.as_str())
        .unwrap_or("default");

    let secrets_tmp = tempfile::tempdir()?;

    // Cache decrypted store files to avoid decrypting the same file multiple times
    let mut store_cache: HashMap<String, HashMap<String, String>> = HashMap::new();

    for (proj_name, proj) in projections {
        // Resolve which store this projection's source managed secret lives in.
        // We read the lab config's secrets.managed.<source>.store to find the store name.
        let lab_config = nix::get_lab_config(ctx, lab_name).ok();
        let store_name = lab_config
            .as_ref()
            .and_then(|lc| {
                lc.pointer(&format!("/secrets/managed/{}/store", proj.source))
                    .and_then(|v| v.as_str())
            })
            .unwrap_or(&proj.source);

        // Decrypt store file (cached)
        let store_data = if let Some(cached) = store_cache.get(store_name) {
            cached.clone()
        } else {
            let enc_path = PathBuf::from(ctx.flake_uri())
                .join("secrets")
                .join(lab_name)
                .join(format!("{store_name}.enc.yaml"));

            if !enc_path.exists() {
                println!(
                    "{} Store '{}' not found at {} — run `cata secrets generate` first",
                    style("!!!").red(),
                    store_name,
                    enc_path.display()
                );
                continue;
            }

            let data = secrets_mod::decrypt_sops_secret(&enc_path)?;
            store_cache.insert(store_name.to_string(), data.clone());
            data
        };

        println!(
            "{} Injecting projection: {} (namespace: {}, from: {})...",
            style(">>>").cyan(),
            style(proj_name).bold(),
            proj.namespace,
            proj.source,
        );

        // Extract source managed secret's keys and apply transforms
        let mut k8s_data: HashMap<String, String> = HashMap::new();

        for (key_name, key_def) in &proj.keys {
            // Source value is at store_data[managed_secret_name][key_name]
            let source_value = store_data
                .get(&format!("{}.{}", proj.source, key_def.from))
                .or_else(|| {
                    // Try nested YAML: the store file has managed secret names as top-level keys
                    // After decryption, sops returns flat key-value pairs
                    // Try the flat format: "managed_secret_name/key_name"
                    store_data.get(&key_def.from)
                })
                .map(|s| s.as_str())
                .unwrap_or("");

            let value = match key_def.transform.as_deref().unwrap_or("none") {
                "base64" => {
                    use base64::Engine;
                    base64::engine::general_purpose::STANDARD.encode(source_value)
                }
                "json-wrap" => {
                    let json_key = key_def.json_key.as_deref().unwrap_or(key_name);
                    serde_json::json!({ json_key: source_value }).to_string()
                }
                _ => source_value.to_string(),
            };

            k8s_data.insert(key_name.clone(), value);
        }

        let secret_manifest = serde_json::json!({
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {
                "name": proj_name,
                "namespace": proj.namespace,
                "labels": { "app.kubernetes.io/managed-by": "catallaxy" }
            },
            "type": "Opaque",
            "stringData": k8s_data,
        });

        let yaml = serde_yaml::to_string(&secret_manifest)?;
        let secret_dir = secrets_tmp.path().join(format!("secrets-{proj_name}"));
        fs::create_dir_all(&secret_dir)?;
        fs::write(secret_dir.join("secret.yaml"), &yaml)?;

        tools::kapp::deploy(
            ctx,
            kube_context,
            &format!("secrets-{proj_name}"),
            &secret_dir.display().to_string(),
            timeout,
        )?;
    }

    Ok(())
}

/// Delete k3s auto-deployed bootstrap resources so kapp can recreate them with proper labels.
///
/// k3s auto-deploy mounts Cilium at boot so nodes get CNI immediately, but kapp can't
/// adopt existing Deployments/DaemonSets because spec.selector is immutable and kapp
/// needs to add its tracking label there. We delete all workload resources (Deployments,
/// DaemonSets) that were auto-deployed (i.e., lack kapp labels) so kapp recreates them.
fn cleanup_bootstrap_resources(kube_context: &str, config: &serde_json::Value) {
    let auto_deploy = config
        .pointer("/provisionerConfig/k3d/autoDeployManifests")
        .and_then(|v| v.as_array());

    if auto_deploy.map_or(true, |a| a.is_empty()) {
        return;
    }

    // Find Deployments and DaemonSets in kube-system without kapp ownership labels
    for kind in &["deployments", "daemonsets"] {
        let output = std::process::Command::new("kubectl")
            .args([
                "--context",
                kube_context,
                "get",
                kind,
                "-n",
                "kube-system",
                "-o",
                "jsonpath={range .items[*]}{.metadata.name},{.metadata.labels.kapp\\.k14s\\.io/app}{'\\n'}{end}",
            ])
            .output();

        let output = match output {
            Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).to_string(),
            _ => continue,
        };

        let unmanaged: Vec<&str> = output
            .lines()
            .filter(|line| {
                let parts: Vec<&str> = line.split(',').collect();
                // name,label — if label is empty, resource isn't kapp-managed
                parts.len() >= 1 && !parts[0].is_empty() && (parts.len() < 2 || parts[1].is_empty())
            })
            .filter_map(|line| line.split(',').next())
            // Only clean up Cilium-related resources from auto-deploy
            .filter(|name| name.starts_with("cilium"))
            .collect();

        if unmanaged.is_empty() {
            continue;
        }

        let kind_singular = if *kind == "deployments" {
            "deployment"
        } else {
            "daemonset"
        };

        println!(
            "{} Cleaning up bootstrap-deployed {}s (kapp will recreate): {}",
            console::style(">>>").cyan(),
            kind_singular,
            unmanaged.join(", ")
        );

        for name in &unmanaged {
            let _ = std::process::Command::new("kubectl")
                .args([
                    "--context",
                    kube_context,
                    "delete",
                    kind_singular,
                    name,
                    "-n",
                    "kube-system",
                    "--ignore-not-found",
                ])
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status();
        }
    }
}

/// Deploy manifests via gitops (argocd or fleet)
async fn apply_gitops(
    _ctx: &CataContext,
    engine: &str,
    manifests_path: &str,
    config: &serde_json::Value,
) -> Result<()> {
    let pointer_base = format!("/deploy/{engine}");
    let repo_url = config
        .pointer(&format!("{pointer_base}/repoUrl"))
        .and_then(|v| v.as_str())
        .unwrap_or("");

    let target_path = config
        .pointer(&format!("{pointer_base}/targetPath"))
        .and_then(|v| v.as_str())
        .unwrap_or("manifests");

    let target_branch = config
        .pointer(&format!("{pointer_base}/targetBranch"))
        .and_then(|v| v.as_str())
        .unwrap_or("main");

    if repo_url.is_empty() {
        bail!("deploy.{engine}.repoUrl must be set for gitops strategy");
    }

    println!("{} GitOps deploy ({engine})", style(">>>").cyan());
    println!("  Repo: {repo_url}");
    println!("  Branch: {target_branch}");
    println!("  Path: {target_path}");
    println!("  Manifests: {manifests_path}");
    println!();
    println!(
        "{} TODO: Clone repo, copy manifests to {target_path}, commit and push to {target_branch}",
        style(">>>").yellow()
    );

    Ok(())
}

//! Apply manifests to a cluster
//!
//! Discovers phases from rendered manifest directories and deploys them
//! sequentially or in parallel via kapp.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result, bail};
use clap::Args;
use console::style;
use serde::Deserialize;

use crate::commands::secrets as secrets_mod;
use crate::config::Context as CataContext;
use crate::{nix, tools};

/// Pre-decrypted SOPS store cache: { store_name → { managed_secret_name → { key → value } } }
pub type SecretsCache = Arc<HashMap<String, HashMap<String, HashMap<String, String>>>>;

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

    /// Pre-decrypted SOPS secrets cache (populated by `lab up` to avoid
    /// repeated YubiKey PIN prompts across cluster deployments).
    #[arg(skip)]
    pub secrets_cache: Option<SecretsCache>,
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

    let projs: HashMap<String, ProjectionConfig> = match serde_json::from_value(projs_value.clone())
    {
        Ok(p) => p,
        Err(e) => {
            eprintln!("Warning: failed to parse projections: {e}");
            return by_phase;
        }
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

    // Get cluster config. When a pre-built package is available (lab up),
    // read from metadata.json to avoid a nix eval. Otherwise eval the flake.
    let config = load_cluster_config(ctx, &cluster, args.manifests_dir.as_deref())?;
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
        // When a lab name is available, build the lab package to get lab-specific
        // manifests. The top-level manifests output is flattened across all labs
        let lab_name = ctx.resolve_lab_name(None)?;
        let lab_pkg = nix::build_lab_package(ctx, &lab_name)?;
        let path = format!("{lab_pkg}/manifests");
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

    if args.force {
        // Force mode: always direct-apply via kapp (used by lab up bootstrap)
        apply_kapp(ctx, &kube_context, &effective_path, &args, &config).await
    } else {
        match strategy {
            "kapp" => apply_kapp(ctx, &kube_context, &effective_path, &args, &config).await,
            "argocd" => apply_gitops(ctx, "argocd", &effective_path, &config).await,
            "fleet" => apply_gitops(ctx, "fleet", &effective_path, &config).await,
            _ => bail!("Unknown deploy strategy: {strategy}"),
        }
    }
}

/// Resolve the kubectl context name for a cluster.
/// Prefers the explicit `kubeContext` field from Nix config (set by provisioner modules).
/// Falls back to provisioner-specific conventions for backward compatibility.
fn resolve_kube_context(config: &serde_json::Value, cluster: &str) -> String {
    // Use explicit kubeContext if available (set by cluster.ref.kubeContext in Nix)
    if let Some(ctx) = config.get("kubeContext").and_then(|v| v.as_str()) {
        if !ctx.is_empty() {
            return ctx.to_string();
        }
    }

    // Fallback: provisioner-specific conventions
    let provisioner = config["provisioner"].as_str().unwrap_or("k3d");
    match provisioner {
        "k3d" => {
            let default_name = format!("catallaxy-{cluster}");
            let k3d_name = config
                .pointer("/provisionerConfig/k3d/clusterName")
                .and_then(|v| v.as_str())
                .unwrap_or(&default_name);
            format!("k3d-{k3d_name}")
        }
        "talos" => format!("{cluster}-admin@{cluster}"),
        _ => cluster.to_string(),
    }
}

/// Load cluster config from package metadata or nix eval.
///
/// When a pre-built manifests dir is provided (e.g., from `lab up`), reads
/// metadata.json from the package root. This avoids a nix eval at runtime.
/// Falls back to nix eval for standalone `apply` commands.
fn load_cluster_config(
    ctx: &CataContext,
    cluster: &str,
    manifests_dir: Option<&str>,
) -> Result<serde_json::Value> {
    // Try reading from package metadata.json (lab up path)
    if let Some(dir) = manifests_dir {
        let manifests_path = Path::new(dir);
        // manifests_dir is either "{pkg}/manifests/{cluster}" or "{pkg}/manifests"
        // metadata.json is at the package root (parent of manifests/)
        let pkg_root = manifests_path
            .ancestors()
            .find(|p| p.join("metadata.json").exists());

        if let Some(root) = pkg_root {
            let metadata_path = root.join("metadata.json");
            if let Ok(content) = fs::read_to_string(&metadata_path) {
                if let Ok(metadata) = serde_json::from_str::<serde_json::Value>(&content) {
                    if let Some(cluster_meta) = metadata.pointer(&format!("/clusters/{cluster}")) {
                        // Build a config that has what apply needs: projections, kubeContext, deploy strategy, labName
                        let mut config = serde_json::json!({});
                        // Copy projections from metadata
                        if let Some(projs) = cluster_meta.get("projections") {
                            config["projections"] = projs.clone();
                        }
                        // Copy secrets metadata for SOPS resolution
                        if let Some(secrets) = metadata.get("secrets") {
                            config["secrets"] = secrets.clone();
                        }
                        config["labName"] = serde_json::Value::String(
                            metadata
                                .get("name")
                                .and_then(|v| v.as_str())
                                .unwrap_or("default")
                                .to_string(),
                        );
                        // Still need kubeContext and deploy strategy from nix eval
                        // for now, merge with nix eval if available
                        if let Ok(nix_config) = load_cluster_config_from_nix(ctx, cluster) {
                            // Nix config is authoritative for runtime fields
                            let mut merged = nix_config;
                            // But use package projections (build-time truth)
                            if let Some(projs) = cluster_meta.get("projections") {
                                merged["projections"] = projs.clone();
                            }
                            return Ok(merged);
                        }
                        return Ok(config);
                    }
                }
            }
        }
    }

    // Fallback: nix eval
    load_cluster_config_from_nix(ctx, cluster)
}

/// Load cluster config via nix eval.
/// Merges lab-level secrets metadata into the per-cluster config so
/// inject_projections can resolve store names without a separate eval.
fn load_cluster_config_from_nix(ctx: &CataContext, cluster: &str) -> Result<serde_json::Value> {
    let config = ctx
        .resolve_lab_name(None)
        .ok()
        .and_then(|lab_name| {
            nix::get_lab_config(ctx, &lab_name).ok().and_then(|lab| {
                let mut cluster_config = nix::get_cluster_config_from_lab(&lab, cluster).ok()?;
                // Merge lab-level secrets (stores + managed) into per-cluster config
                if let Some(secrets) = lab.get("secrets") {
                    cluster_config["secrets"] = secrets.clone();
                }
                Some(cluster_config)
            })
        })
        .or_else(|| nix::get_cluster_config(ctx, cluster).ok())
        .ok_or_else(|| anyhow::anyhow!("Failed to load config for cluster '{cluster}'"))?;
    Ok(config)
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
    if !sops_secrets.is_empty() {
        println!(
            "{} Found projections for phases: {}{}",
            style(">>>").cyan(),
            sops_secrets.keys().cloned().collect::<Vec<_>>().join(", "),
            if args.secrets_cache.is_some() {
                " (cached)"
            } else {
                ""
            },
        );
    }
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
            inject_projections(
                ctx,
                kube_context,
                &cluster_name,
                config,
                projections,
                &timeout,
                args.secrets_cache.as_deref(),
            )?;
        }

        // Skip kapp deploy for phases with no manifest content (projection-only phases)
        let has_manifests = fs::read_dir(&phase.dir)
            .map(|entries| {
                entries.filter_map(|e| e.ok()).any(|e| {
                    e.path()
                        .extension()
                        .map_or(false, |ext| ext == "yaml" || ext == "yml")
                })
            })
            .unwrap_or(false);

        if has_manifests {
            // Restart deployments stuck in ProgressDeadlineExceeded from previous failures.
            // Without this, kapp sees no spec change (noop) and fails on the stale status.
            if let Ok(stuck) = tools::kube::get_stuck_deployments(kube_context) {
                for (ns, name) in &stuck {
                    println!(
                        "{} Restarting stuck deployment {}/{}",
                        style(">>>").yellow(),
                        ns,
                        name
                    );
                    let _ = tools::kube::rollout_restart(kube_context, "deployment", ns, name);
                }
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
        } else {
            println!(
                "{} Skipping deploy for {} (no manifests, secrets-only)",
                style(">>>").yellow(),
                style(&phase.name).bold(),
            );
        }
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
    pre_cache: Option<&HashMap<String, HashMap<String, HashMap<String, String>>>>,
) -> Result<()> {
    // Get lab name from cluster config to find SOPS store files
    let lab_name = config
        .get("labName")
        .and_then(|v| v.as_str())
        .map(String::from)
        .or_else(|| ctx.resolve_lab_name(None).ok())
        .unwrap_or_else(|| "default".to_string());

    let secrets_tmp = tempfile::tempdir()?;

    // Per-call cache for standalone apply (when no pre-populated cache is provided)
    let mut store_cache: HashMap<String, HashMap<String, HashMap<String, String>>> = HashMap::new();

    for (proj_name, proj) in projections {
        // Resolve which store this projection's source managed secret lives in.
        // Uses secrets metadata from config (package or nix eval — no extra eval needed).
        let store_name = config
            .pointer(&format!("/secrets/managed/{}/store", proj.source))
            .and_then(|v| v.as_str())
            .unwrap_or(&proj.source);

        // Resolve decrypted store data: pre-populated cache → per-call cache → decrypt
        let store_data = if let Some(cached) = pre_cache.and_then(|c| c.get(store_name)) {
            cached.clone()
        } else if let Some(cached) = store_cache.get(store_name) {
            cached.clone()
        } else {
            let enc_path = secrets_mod::store_file_path(ctx, &lab_name, store_name);

            if !enc_path.exists() {
                println!(
                    "{} Store '{}' not found at {} — run `cata secrets generate` first",
                    style("!!!").red(),
                    store_name,
                    enc_path.display()
                );
                continue;
            }

            let data = secrets_mod::decrypt_sops_store(&enc_path)?;
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

        // Look up the source managed secret's keys from the nested store data
        let source_keys = store_data.get(&proj.source);
        let mut k8s_data: HashMap<String, String> = HashMap::new();

        for (key_name, key_def) in &proj.keys {
            let source_value = source_keys
                .and_then(|keys| keys.get(&key_def.from))
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

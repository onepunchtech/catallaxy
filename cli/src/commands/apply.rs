use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use clap::Args;
use console::style;
use serde::Deserialize;

use crate::config::Context as CataContext;
use crate::domain::ClusterSpec;
use crate::domain::secrets::{self, SecretsSpec};
use crate::io;
use crate::io::nix;

pub use crate::domain::secrets::SecretsCache;

#[derive(Args)]
pub struct ApplyArgs {
    #[arg(help = "Cluster to apply to. Defaults to the flake fragment")]
    pub cluster: Option<String>,

    #[arg(long, help = "Apply only this bundle")]
    pub bundle: Option<String>,

    #[arg(long, help = "Print what would happen without doing it")]
    pub dry_run: bool,

    #[arg(
        long,
        help = "Apply directly even when the cluster's deploy strategy is GitOps"
    )]
    pub force: bool,

    #[arg(skip)]
    pub manifests_dir: Option<String>,

    #[arg(skip)]
    pub secrets_cache: Option<SecretsCache>,

    #[arg(skip)]
    pub lab_config: Option<serde_json::Value>,

    #[arg(skip)]
    pub kube_context_override: Option<String>,
}

#[derive(Debug, Clone)]
struct BundleDir {
    key: String,
    dir: PathBuf,
    wave: usize,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectionConfig {
    pub source: String,
    pub namespace: String,
    pub keys: HashMap<String, ProjectionKeyConfig>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectionKeyConfig {
    pub from: String,
    pub transform: Option<String>,
    pub json_key: Option<String>,
}

pub fn parse_projections(config: &serde_json::Value) -> HashMap<String, ProjectionConfig> {
    let projs_value = match config.get("projections") {
        Some(v) => v,
        None => return HashMap::new(),
    };

    match serde_json::from_value(projs_value.clone()) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("Warning: failed to parse projections: {e}");
            HashMap::new()
        }
    }
}

pub async fn run(ctx: &CataContext, args: ApplyArgs) -> Result<()> {
    let cluster = ctx.resolve_cluster_name(args.cluster.as_deref())?;

    println!(
        "{} Applying to cluster '{cluster}'",
        style("catallaxy").cyan().bold(),
    );
    println!();

    let config = if let Some(ref lab) = args.lab_config {
        let mut cluster_config = nix::get_cluster_config_from_lab(lab, &cluster)?;
        if let Some(secrets) = lab.get("secrets") {
            cluster_config["secrets"] = secrets.clone();
        }
        cluster_config
    } else {
        load_cluster_config(ctx, &cluster, args.manifests_dir.as_deref())?
    };
    let cluster_spec = ClusterSpec::from_value(config.clone()).ok();
    let strategy = cluster_spec
        .as_ref()
        .and_then(|c| c.deploy_strategy())
        .unwrap_or("kapp");

    if (strategy == "argocd" || strategy == "fleet") && !args.force {
        return Err(deployed_through_git(strategy));
    }

    let kube_context = resolve_kube_context(
        cluster_spec.as_ref(),
        &cluster,
        args.kube_context_override.as_deref(),
    );

    let manifests_path = if let Some(ref dir) = args.manifests_dir {
        println!("{} Using pre-built manifests: {dir}", style(">>>").green());
        dir.clone()
    } else {
        println!("{} Building manifests...", style(">>>").cyan());
        let lab_name = ctx.resolve_lab_name(None)?;
        let lab_pkg = nix::build_lab_package(ctx, &lab_name)?;
        let path = format!("{lab_pkg}/manifests");
        println!("{} Manifests built: {path}", style(">>>").green());
        path
    };

    let cluster_subdir = Path::new(&manifests_path).join(&cluster);
    let effective_path = if cluster_subdir.is_dir() {
        cluster_subdir.display().to_string()
    } else {
        manifests_path.clone()
    };

    if args.force {
        apply_kapp(ctx, &kube_context, &effective_path, &args, &config).await
    } else {
        match strategy {
            "kapp" => apply_kapp(ctx, &kube_context, &effective_path, &args, &config).await,
            "argocd" | "fleet" => Err(deployed_through_git(strategy)),
            _ => bail!("Unknown deploy strategy: {strategy}"),
        }
    }
}

fn resolve_kube_context(
    spec: Option<&ClusterSpec>,
    cluster: &str,
    override_: Option<&str>,
) -> String {
    use crate::domain::ProvisionerKind;

    if let Some(ctx) = override_.filter(|s| !s.is_empty()) {
        return ctx.to_string();
    }
    let Some(spec) = spec else {
        return cluster.to_string();
    };
    if let Some(ctx) = spec.kube_context.as_deref().filter(|s| !s.is_empty()) {
        return ctx.to_string();
    }
    match spec.provisioner {
        ProvisionerKind::K3d => {
            let default_name = format!("catallaxy-{cluster}");
            let k3d_name = spec.k3d_cluster_name().unwrap_or(&default_name);
            format!("k3d-{k3d_name}")
        }
        ProvisionerKind::Talos => format!("{cluster}-admin@{cluster}"),
        _ => cluster.to_string(),
    }
}

fn load_cluster_config(
    ctx: &CataContext,
    cluster: &str,
    manifests_dir: Option<&str>,
) -> Result<serde_json::Value> {
    if let Some(dir) = manifests_dir {
        let manifests_path = Path::new(dir);
        let pkg_root = manifests_path
            .ancestors()
            .find(|p| p.join("metadata.json").exists());

        if let Some(root) = pkg_root {
            let metadata_path = root.join("metadata.json");
            if let Ok(content) = fs::read_to_string(&metadata_path) {
                if let Ok(metadata) = serde_json::from_str::<serde_json::Value>(&content) {
                    if let Some(cluster_meta) = metadata.pointer(&format!("/clusters/{cluster}")) {
                        let mut config = serde_json::json!({});
                        if let Some(projs) = cluster_meta.get("projections") {
                            config["projections"] = projs.clone();
                        }
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
                        if let Ok(nix_config) = load_cluster_config_from_nix(ctx, cluster) {
                            let mut merged = nix_config;
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

    load_cluster_config_from_nix(ctx, cluster)
}

fn load_cluster_config_from_nix(ctx: &CataContext, cluster: &str) -> Result<serde_json::Value> {
    let config = ctx
        .resolve_lab_name(None)
        .ok()
        .and_then(|lab_name| {
            nix::get_lab_config(ctx, &lab_name).ok().and_then(|lab| {
                let mut cluster_config = nix::get_cluster_config_from_lab(&lab, cluster).ok()?;
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

fn kapp_app_name(bundle_key: &str) -> String {
    bundle_key
        .chars()
        .map(|c| {
            let c = c.to_ascii_lowercase();
            if c.is_ascii_alphanumeric() || c == '-' {
                c
            } else {
                '-'
            }
        })
        .collect()
}

fn discover_bundles(cluster_manifests: &Path) -> Result<Vec<BundleDir>> {
    let wave_meta_path = cluster_manifests.join(".wave-meta");
    let raw = fs::read_to_string(&wave_meta_path).with_context(|| {
        format!(
            "reading {}: the manifest tree was rendered by an older \
             catallaxy. Re-render the lab.",
            wave_meta_path.display()
        )
    })?;
    let meta: crate::io::ssa::WaveMeta = serde_json::from_str(&raw)
        .with_context(|| format!("parsing {}", wave_meta_path.display()))?;

    let mut bundles = Vec::new();
    for wave in &meta.waves {
        for b in &wave.bundles {
            if !b.has_content {
                continue;
            }
            bundles.push(BundleDir {
                key: b.key.clone(),
                dir: cluster_manifests.join(&b.dir),
                wave: wave.index,
            });
        }
    }
    Ok(bundles)
}

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

async fn apply_kapp(
    ctx: &CataContext,
    kube_context: &str,
    manifests_path: &str,
    args: &ApplyArgs,
    config: &serde_json::Value,
) -> Result<()> {
    if !io::kubectl::api_reachable(kube_context) {
        bail!("Cannot reach cluster (context: {kube_context}). Is it running?");
    }

    let cluster_manifests = Path::new(manifests_path);
    let timeout = read_deploy_timeout(cluster_manifests);
    let mut bundles = discover_bundles(cluster_manifests)?;

    if let Some(ref key) = args.bundle {
        bundles.retain(|b| b.key == *key);
        if bundles.is_empty() {
            bail!("Bundle '{key}' not found in rendered manifests");
        }
    }

    let projections = parse_projections(config);
    if !projections.is_empty() {
        println!(
            "{} Found {} projection(s){}",
            style(">>>").cyan(),
            projections.len(),
            if args.secrets_cache.is_some() {
                " (cached)"
            } else {
                ""
            },
        );
    }
    let cluster_name = ctx.resolve_cluster_name(args.cluster.as_deref())?;

    if args.dry_run {
        println!("{} Dry run: would deploy:", style("Note:").yellow());
        for b in &bundles {
            println!("  wave {:03}  {}", b.wave, b.key);
        }
        for name in projections.keys() {
            println!("  projection {name}");
        }
        return Ok(());
    }

    if !projections.is_empty() {
        let ordered: Vec<(String, ProjectionConfig)> = projections.into_iter().collect();
        inject_projections(
            ctx,
            kube_context,
            &cluster_name,
            config,
            &ordered,
            &timeout,
            args.secrets_cache.as_deref(),
        )?;
    }

    cleanup_bootstrap_resources(kube_context, config);

    for bundle in &bundles {
        println!(
            "\n{} Bundle: {} (wave {:03})",
            style(">>>").cyan(),
            style(&bundle.key).bold(),
            bundle.wave,
        );

        let crd_wait_file = bundle.dir.join(".crd-wait");
        if crd_wait_file.exists() {
            if let Ok(content) = fs::read_to_string(&crd_wait_file) {
                for crd in content.lines().map(|l| l.trim()).filter(|l| !l.is_empty()) {
                    println!("{} Waiting for CRD: {crd}...", style(">>>").cyan());
                    io::kubectl::wait_crd_established(ctx, kube_context, crd, &timeout)?;
                }
            }
        }

        if let Ok(stuck) = io::kubectl::get_stuck_deployments(kube_context) {
            for (ns, name) in &stuck {
                println!(
                    "{} Restarting stuck deployment {}/{}",
                    style(">>>").yellow(),
                    ns,
                    name
                );
                let _ = io::kubectl::rollout_restart(kube_context, "deployment", ns, name);
            }
        }

        io::kapp::deploy(
            ctx,
            kube_context,
            &kapp_app_name(&bundle.key),
            &bundle.dir.display().to_string(),
            &timeout,
        )?;
    }

    println!();
    println!("{} All bundles deployed", style(">>>").green());

    Ok(())
}

fn inject_projections(
    ctx: &CataContext,
    kube_context: &str,
    _cluster_name: &str,
    config: &serde_json::Value,
    projections: &[(String, ProjectionConfig)],
    timeout: &str,
    pre_cache: Option<&HashMap<String, HashMap<String, HashMap<String, String>>>>,
) -> Result<()> {
    inject_projections_with(
        ctx,
        kube_context,
        config,
        projections,
        pre_cache,
        |secret_dir, secret_name| {
            io::kapp::deploy(
                ctx,
                kube_context,
                &format!("secrets-{secret_name}"),
                &secret_dir.display().to_string(),
                timeout,
            )
        },
    )
}

pub fn inject_projections_with<F>(
    ctx: &CataContext,
    _kube_context: &str,
    config: &serde_json::Value,
    projections: &[(String, ProjectionConfig)],
    pre_cache: Option<&HashMap<String, HashMap<String, HashMap<String, String>>>>,
    mut apply_fn: F,
) -> Result<()>
where
    F: FnMut(&std::path::Path, &str) -> Result<()>,
{
    let lab_name = config
        .get("labName")
        .and_then(|v| v.as_str())
        .map(String::from)
        .or_else(|| ctx.resolve_lab_name(None).ok())
        .unwrap_or_else(|| "default".to_string());

    let secrets_tmp = tempfile::tempdir()?;
    let spec = SecretsSpec::from_lab_config(config)?;

    let mut store_cache: HashMap<String, HashMap<String, HashMap<String, String>>> = HashMap::new();

    for (proj_name, proj) in projections {
        let store_name = spec.store_of(&proj.source).unwrap_or(&proj.source);

        let store_data = if let Some(cached) = pre_cache.and_then(|c| c.get(store_name)) {
            cached.clone()
        } else if let Some(cached) = store_cache.get(store_name) {
            cached.clone()
        } else {
            let data = io::secrets::load_store(ctx, &lab_name, store_name, &spec)?;
            let problems = secrets::validate_store(&spec, store_name, &data);
            if !problems.is_empty() {
                bail!(secrets::describe_store_problems(
                    &spec, &lab_name, store_name, &problems
                ));
            }
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

        let source_keys = store_data.get(&proj.source).ok_or_else(|| {
            anyhow::anyhow!(
                "projection '{proj_name}' references managed secret '{}', which store '{store_name}' does not carry. {}",
                proj.source,
                secrets::describe_store_source(&spec, &lab_name, store_name),
            )
        })?;
        let mut k8s_data: HashMap<String, String> = HashMap::new();

        for (key_name, key_def) in &proj.keys {
            let source_value = source_keys.get(&key_def.from).ok_or_else(|| {
                anyhow::anyhow!(
                    "projection '{proj_name}' wants key '{}' of managed secret '{}': {}",
                    key_def.from,
                    proj.source,
                    secrets::describe_missing_value(
                        &spec,
                        &lab_name,
                        store_name,
                        &proj.source,
                        &key_def.from
                    ),
                )
            })?;
            let source_value = source_value.as_str();

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

        apply_fn(&secret_dir, proj_name)?;
    }

    Ok(())
}

fn cleanup_bootstrap_resources(kube_context: &str, config: &serde_json::Value) {
    let auto_deploy = config
        .pointer("/provisionerConfig/k3d/autoDeployManifests")
        .and_then(|v| v.as_array());

    if auto_deploy.map_or(true, |a| a.is_empty()) {
        return;
    }

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
                parts.len() >= 1 && !parts[0].is_empty() && (parts.len() < 2 || parts[1].is_empty())
            })
            .filter_map(|line| line.split(',').next())
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

fn deployed_through_git(strategy: &str) -> anyhow::Error {
    anyhow::anyhow!(
        "This lab uses '{strategy}' strategy. Manifests must be deployed via Git.\n\
         Use 'cata lab publish' to push manifests to the Git repository.\n\
         To apply directly anyway, use --force."
    )
}

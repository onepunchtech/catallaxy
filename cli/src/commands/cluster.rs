//! Cluster management commands

use std::fs;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::{Result, bail};
use clap::{Args, Subcommand};
use console::style;

use crate::config::Context as CataContext;
use crate::tools;

#[derive(Subcommand)]
pub enum ClusterCommands {
    /// List all defined clusters
    List,

    /// Provision a cluster (creates if needed, does not apply manifests)
    Init {
        /// Cluster name (defaults to flake fragment if provided)
        name: Option<String>,
    },

    /// Provision a cluster and apply manifests (init + apply)
    Up {
        /// Cluster name (defaults to flake fragment if provided)
        name: Option<String>,

        /// Apply only a specific phase
        #[arg(long)]
        phase: Option<String>,

        /// Apply only a specific component
        #[arg(long)]
        component: Option<String>,

        /// Dry run (don't actually apply)
        #[arg(long)]
        dry_run: bool,

        /// Force direct apply even when the lab uses a GitOps strategy
        #[arg(long)]
        force: bool,
    },

    /// Stop and remove a cluster (no-op if not running)
    #[command(alias = "destroy")]
    Down {
        /// Cluster name (defaults to flake fragment if provided)
        name: Option<String>,
    },

    /// Show cluster status
    Status {
        /// Cluster name (defaults to flake fragment if provided)
        name: Option<String>,
    },

    /// Manage kubeconfigs for CAPI-managed workload clusters
    Kubeconfig(KubeconfigArgs),
}

#[derive(Args)]
pub struct KubeconfigArgs {
    #[command(subcommand)]
    pub command: KubeconfigCommands,
}

#[derive(Subcommand)]
pub enum KubeconfigCommands {
    /// Sync kubeconfigs for CAPI-managed clusters
    Sync {
        /// Management cluster name (defaults to flake fragment if provided)
        #[arg(long)]
        management: Option<String>,

        /// Specific workload cluster to sync (waits for it to be ready)
        cluster: Option<String>,

        /// Timeout for waiting (e.g., "5m", "300s"). Only used when a specific cluster is specified.
        #[arg(long, default_value = "10m")]
        timeout: String,
    },
}

pub async fn run(ctx: &CataContext, command: ClusterCommands) -> Result<()> {
    match command {
        ClusterCommands::List => list(ctx).await,
        ClusterCommands::Init { name } => {
            let name = ctx.resolve_cluster_name(name.as_deref())?;
            init(ctx, &name).await
        }
        ClusterCommands::Up {
            name,
            phase,
            component,
            dry_run,
            force,
        } => {
            let name = ctx.resolve_cluster_name(name.as_deref())?;
            up(ctx, &name, phase, component, dry_run, force).await
        }
        ClusterCommands::Down { name } => {
            let name = ctx.resolve_cluster_name(name.as_deref())?;
            down(ctx, &name).await
        }
        ClusterCommands::Status { name } => {
            let name = ctx.resolve_cluster_name(name.as_deref())?;
            status(ctx, &name).await
        }
        ClusterCommands::Kubeconfig(args) => kubeconfig(ctx, args).await,
    }
}

/// Get the provisioner type from cluster config
fn cluster_provisioner(config: &serde_json::Value) -> &str {
    config["provisioner"].as_str().unwrap_or("k3d")
}

/// Get the cluster name used by the provisioner
fn provisioner_cluster_name(config: &serde_json::Value) -> String {
    match cluster_provisioner(config) {
        "k3d" => config
            .pointer("/provisionerConfig/k3d/clusterName")
            .and_then(|v| v.as_str())
            .unwrap_or("catallaxy")
            .to_string(),
        "talos" => config
            .pointer("/provisionerConfig/docker/clusterName")
            .and_then(|v| v.as_str())
            .unwrap_or("catallaxy")
            .to_string(),
        _ => String::new(),
    }
}

/// Resolve the docker host for a cluster config, ensuring colima is running on macOS.
fn resolve_docker_host(ctx: &CataContext, config: &serde_json::Value) -> Result<Option<String>> {
    if !tools::colima::is_macos() {
        return Ok(None);
    }

    let colima_enabled = config
        .pointer("/provisionerConfig/docker/colima/enable")
        .and_then(|v| v.as_bool())
        .unwrap_or(true);

    if !colima_enabled {
        return Ok(None);
    }

    let profile = config
        .pointer("/provisionerConfig/docker/colima/profile")
        .and_then(|v| v.as_str())
        .unwrap_or("catallaxy");

    let cpu = config
        .pointer("/provisionerConfig/docker/colima/cpu")
        .and_then(|v| v.as_u64())
        .unwrap_or(4);

    let memory = config
        .pointer("/provisionerConfig/docker/colima/memory")
        .and_then(|v| v.as_u64())
        .unwrap_or(8);

    let disk = config
        .pointer("/provisionerConfig/docker/colima/disk")
        .and_then(|v| v.as_u64())
        .unwrap_or(60);

    if !tools::colima::profile_running(profile) {
        tools::colima::start(ctx, profile, cpu, memory, disk)?;
    } else {
        println!(
            "{} Colima VM already running (profile: {profile})",
            style(">>>").green()
        );
    }

    Ok(Some(tools::colima::docker_socket(profile)))
}

async fn list(ctx: &CataContext) -> Result<()> {
    println!("{} Defined clusters", style("catallaxy").cyan().bold());
    println!();

    let names = crate::nix::list_clusters(ctx)?;

    if names.is_empty() {
        println!("  (no clusters defined)");
        return Ok(());
    }

    for name in &names {
        match crate::nix::get_cluster_config(ctx, name) {
            Ok(config) => {
                let provisioner = cluster_provisioner(&config);
                println!("  {} ({})", style(name).green(), provisioner);
            }
            Err(_) => {
                println!("  {} (error loading config)", style(name).yellow());
            }
        }
    }

    Ok(())
}

/// Ensure lab infrastructure services are running for any lab that contains this cluster.
/// Returns the path to registries.yaml if the lab has registry enabled.
fn ensure_lab_services(ctx: &CataContext, cluster_name: &str) -> Option<PathBuf> {
    // Best-effort: find labs that contain this cluster and start their services
    let lab_names: Result<Vec<String>> = crate::nix::list_labs(ctx);
    let lab_names = match lab_names {
        Ok(names) => names,
        Err(_) => return None, // No labs output, nothing to do
    };

    for lab_name in &lab_names {
        let lab: serde_json::Value = match crate::nix::get_lab_config(ctx, lab_name) {
            Ok(config) => config,
            Err(_) => continue,
        };

        // Check if this lab contains our cluster
        let contains_cluster = lab["clusterNames"].as_array().map_or(false, |names| {
            names.iter().any(|n| n.as_str() == Some(cluster_name))
        });

        if !contains_cluster {
            continue;
        }

        // Start this lab's services
        if let Some(services) = lab["services"].as_object() {
            for (svc_name, svc) in services {
                if let Err(e) = super::lab::start_service(ctx, lab_name, svc_name, svc) {
                    let description = svc["description"].as_str().unwrap_or(svc_name);
                    println!(
                        "{} Failed to start {}: {}",
                        style("Warning:").yellow(),
                        description,
                        e
                    );
                }
            }
        }

        // Write and return registries.yaml path if registry is enabled
        if let Some(port) = lab.pointer("/registryPort").and_then(|v| v.as_u64()) {
            let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
            let state_dir = PathBuf::from(home)
                .join(".local/share/catallaxy/labs")
                .join(lab_name)
                .join("registry");
            if fs::create_dir_all(&state_dir).is_ok() {
                let path = state_dir.join("registries.yaml");
                let registry_yaml = super::lab::generate_registries_yaml(port as u16);
                if fs::write(&path, registry_yaml).is_ok() {
                    return Some(path);
                }
            }
        }
    }

    None
}

/// Provision a single cluster with optional registry configuration.
/// When registries_yaml is provided, k3d clusters will use it as a mirror config.
pub fn provision_cluster_with_registry(
    ctx: &CataContext,
    name: &str,
    config: &serde_json::Value,
    registries_yaml: Option<&std::path::Path>,
) -> Result<()> {
    let provisioner = cluster_provisioner(config);
    let cluster_name = provisioner_cluster_name(config);

    match provisioner {
        "k3d" => {
            let docker_host = resolve_docker_host(ctx, config)?;
            if tools::k3d::cluster_exists(&cluster_name, docker_host.as_deref()) {
                println!(
                    "{} Cluster '{name}' is already running",
                    style(">>>").green()
                );
                return Ok(());
            }

            let workers = config["kubernetes"]["workers"].as_u64().unwrap_or(0) as u32;
            let no_traefik = config
                .pointer("/provisionerConfig/k3d/noTraefik")
                .and_then(|v| v.as_bool())
                .unwrap_or(true);
            let no_service_lb = config
                .pointer("/provisionerConfig/k3d/noServiceLB")
                .and_then(|v| v.as_bool())
                .unwrap_or(true);
            let no_flannel = config
                .pointer("/provisionerConfig/k3d/noFlannel")
                .and_then(|v| v.as_bool())
                .unwrap_or(true);
            let image = config
                .pointer("/provisionerConfig/k3d/image")
                .and_then(|v| v.as_str());

            let service_cidr = config
                .pointer("/network/serviceSubnet")
                .and_then(|v| v.as_str());
            let pod_cidr = config
                .pointer("/network/podSubnet")
                .and_then(|v| v.as_str());

            let mut auto_deploy: Vec<(String, String)> = config
                .pointer("/provisionerConfig/k3d/autoDeployManifests")
                .and_then(|v| v.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter_map(|m| {
                            let name = m["name"].as_str()?.to_string();
                            let path = m["path"].as_str()?.to_string();
                            Some((name, path))
                        })
                        .collect()
                })
                .unwrap_or_default();

            // Build auto-deploy manifests (nix eval gives store paths but doesn't build them)
            if !auto_deploy.is_empty() {
                let has_unrealized = auto_deploy.iter().any(|(_, p)| {
                    p.starts_with("/nix/store/") && !std::path::Path::new(p).exists()
                });
                if has_unrealized {
                    println!("{} Building auto-deploy manifests...", style(">>>").cyan());
                    let system = crate::nix::current_system();
                    if let Ok(built_path) =
                        crate::nix::build(ctx, &format!("autoDeployManifests.{system}.{name}"))
                    {
                        // Update paths to point to the built link farm
                        auto_deploy = auto_deploy
                            .into_iter()
                            .map(|(n, p)| {
                                let farm_path = format!("{}/{}.yaml", built_path, n);
                                if std::path::Path::new(&farm_path).exists() {
                                    (n, farm_path)
                                } else {
                                    (n, p)
                                }
                            })
                            .collect();
                    }
                }
            }

            let ports: Vec<String> = config
                .pointer("/provisionerConfig/k3d/ports")
                .and_then(|v| v.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter_map(|v| v.as_str().map(String::from))
                        .collect()
                })
                .unwrap_or_default();
            let port_refs: Vec<&str> = ports.iter().map(|s| s.as_str()).collect();

            let network = config
                .pointer("/provisionerConfig/k3d/network")
                .and_then(|v| v.as_str());

            tools::k3d::cluster_create(
                ctx,
                &cluster_name,
                workers,
                no_traefik,
                no_service_lb,
                no_flannel,
                image,
                docker_host.as_deref(),
                registries_yaml
                    .map(|p| p.to_string_lossy().to_string())
                    .as_deref(),
                service_cidr,
                pod_cidr,
                &auto_deploy,
                &port_refs,
                network,
            )?;
        }
        "talos" => {
            let docker_host = resolve_docker_host(ctx, config)?;
            if tools::talos::cluster_exists(&cluster_name, docker_host.as_deref()) {
                println!(
                    "{} Cluster '{name}' is already running",
                    style(">>>").green()
                );
                return Ok(());
            }

            let control_planes = config["kubernetes"]["controlPlanes"].as_u64().unwrap_or(1) as u32;
            let workers = config["kubernetes"]["workers"].as_u64().unwrap_or(1) as u32;

            tools::talos::cluster_create(
                ctx,
                &cluster_name,
                control_planes,
                workers,
                docker_host.as_deref(),
            )?;
        }
        "crossplane" => {
            println!(
                "{} Crossplane clusters are provisioned via CAPI on the management cluster",
                style(">>>").cyan()
            );
        }
        "external" => {
            println!(
                "{} External cluster '{name}' — no provisioning needed",
                style(">>>").cyan()
            );
        }
        other => {
            bail!("Unknown provisioner: {other}");
        }
    }

    Ok(())
}

async fn init(ctx: &CataContext, name: &str) -> Result<()> {
    tools::check_required_tools()?;

    println!(
        "{} Initializing cluster '{name}'",
        style("catallaxy").cyan().bold()
    );

    // Ensure lab infrastructure services (DNS, registry, etc.) are running
    // Returns registries.yaml path if registry is enabled
    let registries_yaml_path = ensure_lab_services(ctx, name);

    // Get cluster config from Nix
    println!("{} Loading cluster configuration...", style(">>>").cyan());
    let config = crate::nix::get_cluster_config(ctx, name)?;

    provision_cluster_with_registry(
        ctx,
        name,
        &config,
        registries_yaml_path.as_ref().map(|p| p.as_path()),
    )?;

    println!();
    println!(
        "{} Cluster '{name}' provisioned. Run 'cata cluster up {name}' or 'cata apply {name}' to deploy manifests.",
        style(">>>").green()
    );

    Ok(())
}

async fn up(
    ctx: &CataContext,
    name: &str,
    phase: Option<String>,
    component: Option<String>,
    dry_run: bool,
    force: bool,
) -> Result<()> {
    // Init (provision the cluster)
    init(ctx, name).await?;

    // Apply manifests
    crate::commands::apply::run(
        ctx,
        crate::commands::apply::ApplyArgs {
            cluster: Some(name.to_string()),
            phase,
            component,
            dry_run,
            force,
            sequential: false,
            manifests_dir: None,
            secrets_cache: None,
        },
    )
    .await
}

/// Stop a single cluster (preserves state). Called by `lab down`.
pub fn stop_cluster(
    ctx: &CataContext,
    name: &str,
    config: &serde_json::Value,
) -> Result<()> {
    let provisioner = cluster_provisioner(config);
    let cluster_name = provisioner_cluster_name(config);

    match provisioner {
        "k3d" => {
            let docker_host = resolve_docker_host(ctx, config)?;
            if !tools::k3d::cluster_exists(&cluster_name, docker_host.as_deref()) {
                println!("{} Cluster '{name}' is not running", style(">>>").green());
                return Ok(());
            }
            tools::k3d::cluster_stop(ctx, &cluster_name, docker_host.as_deref())?;
        }
        "external" | "crossplane" => {
            println!("  {provisioner} cluster '{name}' — nothing to stop locally");
        }
        _ => {
            println!("  Cluster '{name}' ({provisioner}) — stop not supported, skipping");
        }
    }

    Ok(())
}

/// Destroy a single cluster completely. Called by `lab destroy`.
pub fn deprovision_cluster(
    ctx: &CataContext,
    name: &str,
    config: &serde_json::Value,
) -> Result<()> {
    let provisioner = cluster_provisioner(config);
    let cluster_name = provisioner_cluster_name(config);

    match provisioner {
        "k3d" => {
            let docker_host = resolve_docker_host(ctx, config)?;
            if !tools::k3d::cluster_exists(&cluster_name, docker_host.as_deref()) {
                println!("{} Cluster '{name}' is not running", style(">>>").green());
                return Ok(());
            }
            tools::k3d::cluster_destroy(ctx, &cluster_name, docker_host.as_deref())?;
        }
        "talos" => {
            let docker_host = resolve_docker_host(ctx, config)?;
            if !tools::talos::cluster_exists(&cluster_name, docker_host.as_deref()) {
                println!("{} Cluster '{name}' is not running", style(">>>").green());
                return Ok(());
            }
            tools::talos::cluster_destroy(ctx, &cluster_name, docker_host.as_deref())?;
        }
        "crossplane" => {
            println!(
                "{} Crossplane clusters are deprovisioned via CAPI on the management cluster",
                style(">>>").cyan()
            );
        }
        "external" => {
            println!("  External clusters cannot be deleted via cata.");
        }
        other => {
            bail!("Unknown provisioner: {other}");
        }
    }

    Ok(())
}

async fn down(ctx: &CataContext, name: &str) -> Result<()> {
    println!(
        "{} Stopping cluster '{name}'",
        style("catallaxy").cyan().bold()
    );

    let config = crate::nix::get_cluster_config(ctx, name)?;
    deprovision_cluster(ctx, name, &config)
}

async fn status(ctx: &CataContext, name: &str) -> Result<()> {
    println!(
        "{} Cluster '{name}' status",
        style("catallaxy").cyan().bold()
    );
    println!();

    let config = crate::nix::get_cluster_config(ctx, name)?;
    let provisioner = cluster_provisioner(&config);

    println!("{}", style("Configuration:").bold());
    println!("  Provisioner: {provisioner}");
    println!(
        "  Control Planes: {}",
        config["kubernetes"]["controlPlanes"].as_u64().unwrap_or(0)
    );
    println!(
        "  Workers: {}",
        config["kubernetes"]["workers"].as_u64().unwrap_or(0)
    );
    println!();

    let cluster_name = provisioner_cluster_name(&config);
    println!("{}", style("Runtime:").bold());
    match provisioner {
        "k3d" => {
            let docker_host = resolve_docker_host(ctx, &config)?;
            if tools::k3d::cluster_exists(&cluster_name, docker_host.as_deref()) {
                let _ = tools::k3d::cluster_show(ctx, &cluster_name, docker_host.as_deref());
            } else {
                println!("  (not running)");
            }
        }
        "talos" => {
            let docker_host = resolve_docker_host(ctx, &config)?;
            if tools::talos::cluster_exists(&cluster_name, docker_host.as_deref()) {
                let _ = tools::talos::cluster_show(ctx, &cluster_name, docker_host.as_deref());
            } else {
                println!("  (not running)");
            }
        }
        _ => {
            println!("  (status check not available for {provisioner} clusters)");
        }
    }

    Ok(())
}

async fn kubeconfig(ctx: &CataContext, args: KubeconfigArgs) -> Result<()> {
    match args.command {
        KubeconfigCommands::Sync {
            management,
            cluster,
            timeout,
        } => kubeconfig_sync(ctx, management, cluster, &timeout).await,
    }
}

/// Sync kubeconfigs for CAPI-managed clusters
async fn kubeconfig_sync(
    ctx: &CataContext,
    management: Option<String>,
    cluster: Option<String>,
    timeout: &str,
) -> Result<()> {
    // Resolve management cluster
    let mgmt_name = ctx.resolve_cluster_name(management.as_deref())?;
    let config = crate::nix::get_cluster_config(ctx, &mgmt_name)?;

    // Determine kube context for management cluster
    let default_name = format!("catallaxy-{mgmt_name}");
    let kube_context = if cluster_provisioner(&config) == "k3d" {
        let k3d_name = config
            .pointer("/provisionerConfig/k3d/clusterName")
            .and_then(|v| v.as_str())
            .unwrap_or(&default_name);
        format!("k3d-{k3d_name}")
    } else {
        mgmt_name.clone()
    };

    // Check management cluster is reachable
    if !tools::kube::api_reachable(&kube_context) {
        bail!("Cannot reach management cluster (context: {kube_context}). Is it running?");
    }

    // Get CAPI namespace
    let namespace = config
        .pointer("/components/cluster-api/namespace")
        .and_then(|v| v.as_str())
        .unwrap_or("capi-system");

    // Get defined CAPI clusters
    let clusters = config.pointer("/components/cluster-api/clusters");
    let clusters_map = clusters
        .and_then(|v| v.as_object())
        .ok_or_else(|| anyhow::anyhow!("No CAPI clusters defined in config"))?;

    if clusters_map.is_empty() {
        println!("{} No CAPI clusters defined", style(">>>").yellow());
        return Ok(());
    }

    println!(
        "{} Syncing kubeconfigs from management cluster '{}'",
        style("catallaxy").cyan().bold(),
        mgmt_name
    );
    println!();

    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let kube_dir = PathBuf::from(&home).join(".kube");

    // If a specific cluster is requested, wait for it
    if let Some(ref target_cluster) = cluster {
        if !clusters_map.contains_key(target_cluster) {
            bail!(
                "Cluster '{}' not found in CAPI clusters config",
                target_cluster
            );
        }

        sync_single_cluster(
            &kube_context,
            target_cluster,
            namespace,
            &kube_dir,
            timeout,
            true, // wait for ready
        )?;
    } else {
        // Sync all ready clusters (no waiting)
        for (cluster_name, cluster_config) in clusters_map {
            let enabled = cluster_config
                .get("enable")
                .and_then(|v| v.as_bool())
                .unwrap_or(true);

            if !enabled {
                continue;
            }

            sync_single_cluster(
                &kube_context,
                cluster_name,
                namespace,
                &kube_dir,
                timeout,
                false, // don't wait
            )?;
        }
    }

    Ok(())
}

/// Sync kubeconfig for a single CAPI cluster
fn sync_single_cluster(
    kube_context: &str,
    cluster_name: &str,
    namespace: &str,
    kube_dir: &PathBuf,
    timeout: &str,
    wait: bool,
) -> Result<()> {
    if wait {
        // Wait for cluster to be ready
        println!(
            "{} Waiting for cluster '{}' to be ready...",
            style(">>>").cyan(),
            cluster_name
        );

        let timeout_duration = parse_timeout(timeout);
        let start = Instant::now();

        loop {
            if tools::clusterctl::is_cluster_ready(kube_context, cluster_name, namespace) {
                break;
            }

            if start.elapsed() > timeout_duration {
                bail!(
                    "Timed out waiting for cluster '{}' to be ready",
                    cluster_name
                );
            }

            std::thread::sleep(Duration::from_secs(5));
            print!(".");
            use std::io::Write;
            let _ = std::io::stdout().flush();
        }
        println!();

        // Also wait for kubeconfig secret to exist
        println!("{} Waiting for kubeconfig secret...", style(">>>").cyan());

        loop {
            match tools::kube::get_capi_kubeconfig(kube_context, cluster_name, namespace) {
                Ok(_) => break,
                Err(e) => {
                    let err_str = e.to_string();
                    if !err_str.contains("NotFound") && !err_str.contains("not found") {
                        return Err(e);
                    }
                }
            }

            if start.elapsed() > timeout_duration {
                bail!(
                    "Timed out waiting for kubeconfig secret for '{}'",
                    cluster_name
                );
            }

            std::thread::sleep(Duration::from_secs(2));
            print!(".");
            use std::io::Write;
            let _ = std::io::stdout().flush();
        }
        println!();
    } else {
        // Check readiness without waiting
        if !tools::clusterctl::is_cluster_ready(kube_context, cluster_name, namespace) {
            println!(
                "  {} Cluster '{}' not ready yet, skipping",
                style("-").yellow(),
                cluster_name
            );
            return Ok(());
        }
    }

    // Extract kubeconfig
    let kubeconfig_content =
        match tools::kube::get_capi_kubeconfig(kube_context, cluster_name, namespace) {
            Ok(content) => content,
            Err(e) => {
                let err_str = e.to_string();
                if err_str.contains("NotFound") || err_str.contains("not found") {
                    println!(
                        "  {} Cluster '{}' ready but kubeconfig not available yet, skipping",
                        style("-").yellow(),
                        cluster_name
                    );
                    return Ok(());
                }
                return Err(e);
            }
        };

    // Save to ~/.kube/<cluster>.kubeconfig
    let kubeconfig_path = kube_dir.join(format!("{cluster_name}.kubeconfig"));
    fs::write(&kubeconfig_path, &kubeconfig_content)?;

    // Merge into default kubeconfig
    let context_name = format!("{cluster_name}-admin");
    tools::kube::merge_kubeconfig(&kubeconfig_path, &context_name)?;

    println!(
        "  {} Kubeconfig synced for '{}' (context: {})",
        style("+").green(),
        cluster_name,
        context_name
    );

    Ok(())
}

fn parse_timeout(timeout: &str) -> Duration {
    let s = timeout.trim_end_matches('m').trim_end_matches('s');
    if timeout.ends_with('m') {
        Duration::from_secs(s.parse::<u64>().unwrap_or(10) * 60)
    } else {
        Duration::from_secs(s.parse::<u64>().unwrap_or(600))
    }
}

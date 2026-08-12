use std::fs;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::{Result, bail};
use clap::{Args, Subcommand};
use console::style;

use crate::config::Context as CataContext;
use crate::io;

const CLUSTER_NAME_HELP: &str = "Cluster to act on. Defaults to the flake fragment";

#[derive(Subcommand)]
pub enum ClusterCommands {
    #[command(about = "List clusters across all labs")]
    List,

    #[command(about = "Provision the cluster only, applying no manifests")]
    Init {
        #[arg(help = CLUSTER_NAME_HELP)]
        name: Option<String>,
    },

    #[command(about = "Provision the cluster and apply its manifests")]
    Up {
        #[arg(help = CLUSTER_NAME_HELP)]
        name: Option<String>,

        #[arg(long, help = "Apply only this bundle")]
        bundle: Option<String>,

        #[arg(long, help = "Print what would happen without doing it")]
        dry_run: bool,

        #[arg(
            long,
            help = "Apply directly even when the cluster's deploy strategy is GitOps"
        )]
        force: bool,
    },

    #[command(alias = "destroy", about = "Stop and remove the cluster")]
    Down {
        #[arg(help = CLUSTER_NAME_HELP)]
        name: Option<String>,
    },

    #[command(about = "Show the cluster's current state")]
    Status {
        #[arg(help = CLUSTER_NAME_HELP)]
        name: Option<String>,
    },

    #[command(about = "Manage kubeconfigs for CAPI-managed clusters")]
    Kubeconfig(KubeconfigArgs),
}

#[derive(Args)]
pub struct KubeconfigArgs {
    #[command(subcommand)]
    pub command: KubeconfigCommands,
}

#[derive(Subcommand)]
pub enum KubeconfigCommands {
    #[command(about = "Fetch kubeconfigs for CAPI-managed clusters")]
    Sync {
        #[arg(
            long,
            value_name = "NAME",
            help = "Management cluster to fetch from. Defaults to the flake fragment"
        )]
        management: Option<String>,

        #[arg(help = "Workload cluster to fetch. Defaults to all of them")]
        cluster: Option<String>,

        #[arg(
            long,
            default_value = "10m",
            value_name = "DURATION",
            help = "How long to wait for a cluster to become ready"
        )]
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
            bundle,
            dry_run,
            force,
        } => {
            let name = ctx.resolve_cluster_name(name.as_deref())?;
            up(ctx, &name, bundle, dry_run, force).await
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

fn cluster_provisioner(config: &serde_json::Value) -> &str {
    config["provisioner"].as_str().unwrap_or("k3d")
}

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

pub fn resolve_docker_host(
    ctx: &CataContext,
    config: &serde_json::Value,
) -> Result<Option<String>> {
    if !io::colima::is_macos() {
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

    if !io::colima::profile_running(profile) {
        io::colima::start(ctx, profile, cpu, memory, disk)?;
    } else {
        println!(
            "{} Colima VM already running (profile: {profile})",
            style(">>>").green()
        );
    }

    Ok(Some(io::colima::docker_socket(profile)))
}

async fn list(ctx: &CataContext) -> Result<()> {
    println!("{} Defined clusters", style("catallaxy").cyan().bold());
    println!();

    let names = crate::io::nix::list_clusters(ctx)?;

    if names.is_empty() {
        println!("  (no clusters defined)");
        return Ok(());
    }

    for name in &names {
        match crate::io::nix::get_cluster_config(ctx, name) {
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

fn ensure_lab_services(ctx: &CataContext, cluster_name: &str) -> Option<PathBuf> {
    let lab_names: Result<Vec<String>> = crate::io::nix::list_labs(ctx);
    let lab_names = match lab_names {
        Ok(names) => names,
        Err(_) => return None,
    };

    for lab_name in &lab_names {
        let lab: serde_json::Value = match crate::io::nix::get_lab_config(ctx, lab_name) {
            Ok(config) => config,
            Err(_) => continue,
        };

        let contains_cluster = lab["clusterNames"].as_array().map_or(false, |names| {
            names.iter().any(|n| n.as_str() == Some(cluster_name))
        });

        if !contains_cluster {
            continue;
        }

        if let Some(services) = lab["services"].as_object() {
            for (svc_name, svc) in services {
                if let Err(e) = super::lab::services::start_service(ctx, lab_name, svc_name, svc) {
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

        if let Some(port) = lab.pointer("/registryPort").and_then(|v| v.as_u64()) {
            let state_dir = super::lab::state::service_state_dir(lab_name, "registry");
            if fs::create_dir_all(&state_dir).is_ok() {
                let path = state_dir.join("registries.yaml");
                let upstreams: Vec<String> = lab
                    .pointer("/registryUpstreams")
                    .and_then(|v| v.as_array())
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|v| v.as_str().map(str::to_owned))
                            .collect()
                    })
                    .unwrap_or_default();
                let registry_yaml =
                    super::lab::services::generate_registries_yaml(port as u16, &upstreams);
                if let Some(zone) = lab.pointer("/dnsInfo/zone").and_then(|v| v.as_str()) {
                    let host_dir = state_dir.join("certs.d").join(format!("registry.{zone}"));
                    if fs::create_dir_all(&host_dir).is_ok() {
                        let _ = fs::write(
                            host_dir.join("hosts.toml"),
                            super::lab::services::generate_registry_hosts_toml(zone),
                        );
                        let ca_src =
                            super::lab::state::service_state_dir(lab_name, "proxy").join("ca.crt");
                        if ca_src.exists() {
                            let _ = fs::copy(&ca_src, host_dir.join("ca.crt"));
                        }
                    }
                }
                if lab.get("dnsInfo").map(|v| !v.is_null()).unwrap_or(false) {
                    let dns_ip = std::process::Command::new("docker")
                        .args([
                            "inspect",
                            "--format",
                            "{{range .NetworkSettings.Networks}}{{.IPAddress}}\n{{end}}",
                            "catallaxy-dns",
                        ])
                        .output()
                        .ok()
                        .filter(|o| o.status.success())
                        .and_then(|o| {
                            String::from_utf8(o.stdout).ok().and_then(|s| {
                                s.lines()
                                    .map(|l| l.trim().to_string())
                                    .find(|l| !l.is_empty())
                            })
                        });
                    if let Some(dns_ip) = dns_ip {
                        let resolv = format!(
                            "# Auto-generated by catallaxy.\n\
                             nameserver {dns_ip}\n\
                             nameserver 1.1.1.1\n\
                             nameserver 8.8.8.8\n\
                             options timeout:1 attempts:1\n"
                        );
                        let _ = fs::write(state_dir.join("lab-resolv.conf"), resolv);
                    }
                }
                if fs::write(&path, registry_yaml).is_ok() {
                    return Some(path);
                }
            }
        }
    }

    None
}

fn run_pre_provision_hooks(name: &str, config: &serde_json::Value) -> Result<()> {
    let Some(hooks) = config
        .pointer("/lifecycle/preProvision")
        .and_then(|v| v.as_array())
    else {
        return Ok(());
    };

    for hook in hooks {
        let hook_name = hook["name"].as_str().unwrap_or("preProvision");
        let hook_desc = hook["description"].as_str().unwrap_or(hook_name);
        let bin = hook["bin"].as_str().unwrap_or("");

        if bin.is_empty() {
            continue;
        }

        println!("{} [{name}] {hook_desc}...", style(">>>").cyan());

        let status = std::process::Command::new(bin).status().map_err(|e| {
            anyhow::anyhow!("failed to exec preProvision hook `{bin}` for cluster `{name}`: {e}")
        })?;

        if !status.success() {
            bail!(
                "preProvision hook `{hook_name}` for cluster `{name}` failed \
                 (exit {}). See message above; the hook's stderr explains the \
                 fix.",
                status.code().unwrap_or(-1)
            );
        }
    }

    Ok(())
}

pub fn provision_cluster_with_registry(
    ctx: &CataContext,
    name: &str,
    config: &serde_json::Value,
    registries_yaml: Option<&std::path::Path>,
    lab_package: Option<&str>,
) -> Result<()> {
    let provisioner = cluster_provisioner(config);
    let cluster_name = provisioner_cluster_name(config);

    run_pre_provision_hooks(name, config)?;

    match provisioner {
        "k3d" => {
            let docker_host = resolve_docker_host(ctx, config)?;
            if io::k3d::cluster_exists(&cluster_name, docker_host.as_deref()) {
                println!(
                    "{} Cluster '{name}' is already running",
                    style(">>>").green()
                );
                io::k3d::kubeconfig_merge(&cluster_name, docker_host.as_deref())?;
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
                .unwrap_or(false);
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

            if !auto_deploy.is_empty() {
                let lab_pkg = if let Some(pkg) = lab_package {
                    Some(pkg.to_string())
                } else if let Ok(lab_name) = ctx.resolve_lab_name(None) {
                    crate::io::nix::build_lab_package(ctx, &lab_name).ok()
                } else {
                    None
                };
                if let Some(lab_pkg) = lab_pkg {
                    auto_deploy = auto_deploy
                        .into_iter()
                        .map(|(n, p)| {
                            let pkg_path = format!("{lab_pkg}/autodeploy/{name}/{n}.yaml");
                            if std::path::Path::new(&pkg_path).exists() {
                                (n, pkg_path)
                            } else {
                                (n, p)
                            }
                        })
                        .collect();
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

            let registries_yaml_str = registries_yaml.map(|p| p.to_string_lossy().to_string());
            let registry_dir = registries_yaml.and_then(|p| p.parent().map(|d| d.to_path_buf()));
            let certs_d_str = registry_dir
                .as_ref()
                .map(|d| d.join("certs.d"))
                .filter(|p| p.exists())
                .map(|p| p.to_string_lossy().to_string());
            let resolv_conf_str = registry_dir
                .as_ref()
                .map(|d| d.join("lab-resolv.conf"))
                .filter(|p| p.exists())
                .map(|p| p.to_string_lossy().to_string());

            io::k3d::cluster_create(
                ctx,
                &cluster_name,
                workers,
                no_traefik,
                no_service_lb,
                no_flannel,
                image,
                docker_host.as_deref(),
                registries_yaml_str.as_deref(),
                certs_d_str.as_deref(),
                resolv_conf_str.as_deref(),
                service_cidr,
                pod_cidr,
                &auto_deploy,
                &port_refs,
                network,
            )?;
        }
        "talos" => {
            let docker_host = resolve_docker_host(ctx, config)?;
            if io::talos::cluster_exists(&cluster_name, docker_host.as_deref()) {
                println!(
                    "{} Cluster '{name}' is already running",
                    style(">>>").green()
                );
                return Ok(());
            }

            let control_planes = config["kubernetes"]["controlPlanes"].as_u64().unwrap_or(1) as u32;
            let workers = config["kubernetes"]["workers"].as_u64().unwrap_or(1) as u32;

            io::talos::cluster_create(
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
                "{} External cluster '{name}', no provisioning needed",
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
    io::process::check_required_tools()?;

    println!(
        "{} Initializing cluster '{name}'",
        style("catallaxy").cyan().bold()
    );

    let registries_yaml_path = ensure_lab_services(ctx, name);

    println!("{} Loading cluster configuration...", style(">>>").cyan());
    let config = crate::io::nix::get_cluster_config(ctx, name)?;

    provision_cluster_with_registry(
        ctx,
        name,
        &config,
        registries_yaml_path.as_ref().map(|p| p.as_path()),
        None,
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
    bundle: Option<String>,
    dry_run: bool,
    force: bool,
) -> Result<()> {
    init(ctx, name).await?;

    crate::commands::apply::run(
        ctx,
        crate::commands::apply::ApplyArgs {
            cluster: Some(name.to_string()),
            bundle,
            dry_run,
            force,
            manifests_dir: None,
            secrets_cache: None,
            lab_config: None,
            kube_context_override: None,
        },
    )
    .await
}

pub fn stop_cluster(ctx: &CataContext, name: &str, config: &serde_json::Value) -> Result<()> {
    let provisioner = cluster_provisioner(config);
    let cluster_name = provisioner_cluster_name(config);

    match provisioner {
        "k3d" => {
            let docker_host = resolve_docker_host(ctx, config)?;
            if !io::k3d::cluster_exists(&cluster_name, docker_host.as_deref()) {
                println!("{} Cluster '{name}' is not running", style(">>>").green());
                return Ok(());
            }
            io::k3d::cluster_stop(ctx, &cluster_name, docker_host.as_deref())?;
        }
        "external" | "crossplane" => {
            println!("  {provisioner} cluster '{name}', nothing to stop locally");
        }
        _ => {
            println!("  Cluster '{name}' ({provisioner}): stop not supported, skipping");
        }
    }

    Ok(())
}

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
            if !io::k3d::cluster_exists(&cluster_name, docker_host.as_deref()) {
                println!("{} Cluster '{name}' is not running", style(">>>").green());
                return Ok(());
            }
            io::k3d::cluster_destroy(ctx, &cluster_name, docker_host.as_deref())?;
        }
        "talos" => {
            let docker_host = resolve_docker_host(ctx, config)?;
            if !io::talos::cluster_exists(&cluster_name, docker_host.as_deref()) {
                println!("{} Cluster '{name}' is not running", style(">>>").green());
                return Ok(());
            }
            io::talos::cluster_destroy(ctx, &cluster_name, docker_host.as_deref())?;
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

    let config = crate::io::nix::get_cluster_config(ctx, name)?;
    deprovision_cluster(ctx, name, &config)
}

async fn status(ctx: &CataContext, name: &str) -> Result<()> {
    println!(
        "{} Cluster '{name}' status",
        style("catallaxy").cyan().bold()
    );
    println!();

    let config = crate::io::nix::get_cluster_config(ctx, name)?;
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
            if io::k3d::cluster_exists(&cluster_name, docker_host.as_deref()) {
                let _ = io::k3d::cluster_show(ctx, &cluster_name, docker_host.as_deref());
            } else {
                println!("  (not running)");
            }
        }
        "talos" => {
            let docker_host = resolve_docker_host(ctx, &config)?;
            if io::talos::cluster_exists(&cluster_name, docker_host.as_deref()) {
                let _ = io::talos::cluster_show(ctx, &cluster_name, docker_host.as_deref());
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

async fn kubeconfig_sync(
    ctx: &CataContext,
    management: Option<String>,
    cluster: Option<String>,
    timeout: &str,
) -> Result<()> {
    let mgmt_name = ctx.resolve_cluster_name(management.as_deref())?;
    let config = crate::io::nix::get_cluster_config(ctx, &mgmt_name)?;

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

    if !io::kubectl::api_reachable(&kube_context) {
        bail!("Cannot reach management cluster (context: {kube_context}). Is it running?");
    }

    let namespace = config
        .pointer("/components/cluster-api/namespace")
        .and_then(|v| v.as_str())
        .unwrap_or("capi-system");

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
            true,
        )?;
    } else {
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
                false,
            )?;
        }
    }

    Ok(())
}

fn sync_single_cluster(
    kube_context: &str,
    cluster_name: &str,
    namespace: &str,
    kube_dir: &PathBuf,
    timeout: &str,
    wait: bool,
) -> Result<()> {
    if wait {
        println!(
            "{} Waiting for cluster '{}' to be ready...",
            style(">>>").cyan(),
            cluster_name
        );

        let timeout_duration = parse_timeout(timeout);
        let start = Instant::now();

        loop {
            if io::clusterctl::is_cluster_ready(kube_context, cluster_name, namespace) {
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

        println!("{} Waiting for kubeconfig secret...", style(">>>").cyan());

        loop {
            match io::kubectl::get_capi_kubeconfig(kube_context, cluster_name, namespace) {
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
        if !io::clusterctl::is_cluster_ready(kube_context, cluster_name, namespace) {
            println!(
                "  {} Cluster '{}' not ready yet, skipping",
                style("-").yellow(),
                cluster_name
            );
            return Ok(());
        }
    }

    let kubeconfig_content =
        match io::kubectl::get_capi_kubeconfig(kube_context, cluster_name, namespace) {
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

    let kubeconfig_path = kube_dir.join(format!("{cluster_name}.kubeconfig"));
    fs::write(&kubeconfig_path, &kubeconfig_content)?;

    let context_name = format!("{cluster_name}-admin");
    io::kubectl::merge_kubeconfig(&kubeconfig_path, &context_name)?;

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

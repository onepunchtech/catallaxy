use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{Result, bail};
use clap::{Args, Subcommand};
use console::style;

use crate::config::Context as CataContext;
use crate::domain::lab::kube_context_in;
use crate::domain::{ClusterSpec, ProvisionerKind};
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

fn provisioner_cluster_name(spec: &ClusterSpec) -> &str {
    match spec.provisioner {
        ProvisionerKind::K3d => &spec.provisioner_config.k3d.cluster_name,
        ProvisionerKind::Talos => &spec.provisioner_config.docker.cluster_name,
        ProvisionerKind::Crossplane | ProvisionerKind::External => "",
    }
}

pub fn resolve_docker_host(ctx: &CataContext, spec: &ClusterSpec) -> Result<Option<String>> {
    if !io::colima::is_macos() {
        return Ok(None);
    }

    let colima = &spec.provisioner_config.docker.colima;
    if !colima.enable {
        return Ok(None);
    }

    if io::colima::profile_running(&colima.profile) {
        println!(
            "{} Colima VM already running (profile: {})",
            style(">>>").green(),
            colima.profile
        );
    } else {
        io::colima::start(ctx, &colima.profile, colima.cpu, colima.memory, colima.disk)?;
    }

    Ok(Some(io::colima::docker_socket(&colima.profile)))
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
        match load_cluster_spec(ctx, name) {
            Ok(spec) => {
                println!("  {} ({})", style(name).green(), spec.provider);
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

        let contains_cluster = lab["clusterNames"]
            .as_array()
            .is_some_and(|names| names.iter().any(|n| n.as_str() == Some(cluster_name)));

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

fn run_pre_provision_hooks(name: &str, spec: &ClusterSpec) -> Result<()> {
    for hook in &spec.lifecycle.pre_provision {
        if hook.bin.is_empty() {
            continue;
        }

        println!("{} [{name}] {}...", style(">>>").cyan(), hook.description);

        let status = std::process::Command::new(&hook.bin)
            .status()
            .map_err(|e| {
                anyhow::anyhow!(
                    "failed to exec preProvision hook `{}` for cluster `{name}`: {e}",
                    hook.bin
                )
            })?;

        if !status.success() {
            bail!(
                "preProvision hook `{}` for cluster `{name}` failed \
                 (exit {}). See message above; the hook's stderr explains the \
                 fix.",
                hook.name,
                status.code().unwrap_or(-1)
            );
        }
    }

    Ok(())
}

pub fn provision_cluster_with_registry(
    ctx: &CataContext,
    name: &str,
    spec: &ClusterSpec,
    registries_yaml: Option<&std::path::Path>,
    lab_package: Option<&str>,
) -> Result<()> {
    let cluster_name = provisioner_cluster_name(spec).to_string();

    run_pre_provision_hooks(name, spec)?;

    match spec.provisioner {
        ProvisionerKind::K3d => {
            provision_k3d(ctx, name, &cluster_name, spec, registries_yaml, lab_package)?;
        }
        ProvisionerKind::Talos => {
            let docker_host = resolve_docker_host(ctx, spec)?;
            if io::talos::cluster_exists(&cluster_name, docker_host.as_deref()) {
                println!(
                    "{} Cluster '{name}' is already running",
                    style(">>>").green()
                );
                return Ok(());
            }

            io::talos::cluster_create(
                ctx,
                &cluster_name,
                spec.kubernetes.control_planes,
                spec.kubernetes.workers,
                docker_host.as_deref(),
            )?;
        }
        ProvisionerKind::Crossplane => {
            println!(
                "{} Crossplane clusters are provisioned via CAPI on the management cluster",
                style(">>>").cyan()
            );
        }
        ProvisionerKind::External => {
            println!(
                "{} External cluster '{name}', no provisioning needed",
                style(">>>").cyan()
            );
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
    let spec = load_cluster_spec(ctx, name)?;

    provision_cluster_with_registry(ctx, name, &spec, registries_yaml_path.as_deref(), None)?;

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

    crate::commands::apply::apply(
        ctx,
        crate::commands::apply::ApplyRequest {
            bundle: bundle.as_deref(),
            dry_run,
            force,
            ..crate::commands::apply::ApplyRequest::for_cluster(name)
        },
    )
    .await
}

pub fn stop_cluster(ctx: &CataContext, name: &str, spec: &ClusterSpec) -> Result<()> {
    let cluster_name = provisioner_cluster_name(spec).to_string();

    match spec.provisioner {
        ProvisionerKind::K3d => {
            let docker_host = resolve_docker_host(ctx, spec)?;
            if !io::k3d::cluster_exists(&cluster_name, docker_host.as_deref()) {
                println!("{} Cluster '{name}' is not running", style(">>>").green());
                return Ok(());
            }
            io::k3d::cluster_stop(ctx, &cluster_name, docker_host.as_deref())?;
        }
        ProvisionerKind::External | ProvisionerKind::Crossplane => {
            println!(
                "  {} cluster '{name}', nothing to stop locally",
                spec.provider
            );
        }
        ProvisionerKind::Talos => {
            println!("  Cluster '{name}' (talos): stop not supported, skipping");
        }
    }

    Ok(())
}

pub fn deprovision_cluster(ctx: &CataContext, name: &str, spec: &ClusterSpec) -> Result<()> {
    let cluster_name = provisioner_cluster_name(spec).to_string();

    match spec.provisioner {
        ProvisionerKind::K3d => {
            let docker_host = resolve_docker_host(ctx, spec)?;
            if !io::k3d::cluster_exists(&cluster_name, docker_host.as_deref()) {
                println!("{} Cluster '{name}' is not running", style(">>>").green());
                return Ok(());
            }
            io::k3d::cluster_destroy(ctx, &cluster_name, docker_host.as_deref())?;
        }
        ProvisionerKind::Talos => {
            let docker_host = resolve_docker_host(ctx, spec)?;
            if !io::talos::cluster_exists(&cluster_name, docker_host.as_deref()) {
                println!("{} Cluster '{name}' is not running", style(">>>").green());
                return Ok(());
            }
            io::talos::cluster_destroy(ctx, &cluster_name, docker_host.as_deref())?;
        }
        ProvisionerKind::Crossplane => {
            println!(
                "{} Crossplane clusters are deprovisioned via CAPI on the management cluster",
                style(">>>").cyan()
            );
        }
        ProvisionerKind::External => {
            println!("  External clusters cannot be deleted via cata.");
        }
    }

    Ok(())
}

async fn down(ctx: &CataContext, name: &str) -> Result<()> {
    println!(
        "{} Stopping cluster '{name}'",
        style("catallaxy").cyan().bold()
    );

    let spec = load_cluster_spec(ctx, name)?;
    deprovision_cluster(ctx, name, &spec)
}

async fn status(ctx: &CataContext, name: &str) -> Result<()> {
    println!(
        "{} Cluster '{name}' status",
        style("catallaxy").cyan().bold()
    );
    println!();

    let spec = load_cluster_spec(ctx, name)?;

    println!("{}", style("Configuration:").bold());
    println!("  Provisioner: {}", spec.provider);
    println!("  Control Planes: {}", spec.kubernetes.control_planes);
    println!("  Workers: {}", spec.kubernetes.workers);
    println!();

    let cluster_name = provisioner_cluster_name(&spec).to_string();
    println!("{}", style("Runtime:").bold());
    match spec.provisioner {
        ProvisionerKind::K3d => {
            let docker_host = resolve_docker_host(ctx, &spec)?;
            if io::k3d::cluster_exists(&cluster_name, docker_host.as_deref()) {
                let _ = io::k3d::cluster_show(ctx, &cluster_name, docker_host.as_deref());
            } else {
                println!("  (not running)");
            }
        }
        ProvisionerKind::Talos => {
            let docker_host = resolve_docker_host(ctx, &spec)?;
            if io::talos::cluster_exists(&cluster_name, docker_host.as_deref()) {
                let _ = io::talos::cluster_show(ctx, &cluster_name, docker_host.as_deref());
            } else {
                println!("  (not running)");
            }
        }
        ProvisionerKind::Crossplane | ProvisionerKind::External => {
            println!(
                "  (status check not available for {} clusters)",
                spec.provider
            );
        }
    }

    Ok(())
}

fn load_cluster_spec(ctx: &CataContext, name: &str) -> Result<ClusterSpec> {
    let lab_name = ctx.resolve_lab_name(None)?;
    let lab = crate::io::nix::get_lab_config(ctx, &lab_name)?;
    crate::io::nix::get_cluster_spec_from_lab(&lab, name)
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
    let lab_name = ctx.resolve_lab_name(None)?;
    let lab = crate::io::nix::get_lab_config(ctx, &lab_name)?;
    let config = crate::io::nix::get_cluster_config_from_lab(&lab, &mgmt_name)?;
    let kube_context = kube_context_in(&lab, &mgmt_name)?.to_string();

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
    kube_dir: &Path,
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

fn provision_k3d(
    ctx: &CataContext,
    name: &str,
    cluster_name: &str,
    spec: &ClusterSpec,
    registries_yaml: Option<&std::path::Path>,
    lab_package: Option<&str>,
) -> Result<()> {
    let docker_host = resolve_docker_host(ctx, spec)?;
    if io::k3d::cluster_exists(cluster_name, docker_host.as_deref()) {
        println!(
            "{} Cluster '{name}' is already running",
            style(">>>").green()
        );
        io::k3d::kubeconfig_merge(cluster_name, docker_host.as_deref())?;
        return Ok(());
    }

    let k3d = &spec.provisioner_config.k3d;
    let auto_deploy = resolve_auto_deploy(ctx, name, spec, lab_package);
    let port_refs: Vec<&str> = k3d.ports.iter().map(String::as_str).collect();

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
        io::k3d::ClusterCreate {
            name: cluster_name,
            workers: spec.kubernetes.workers,
            no_traefik: k3d.no_traefik,
            no_service_lb: k3d.no_service_lb,
            no_flannel: k3d.no_flannel,
            image: k3d.image.as_deref(),
            docker_host: docker_host.as_deref(),
            registries_yaml: registries_yaml_str.as_deref(),
            certs_d: certs_d_str.as_deref(),
            resolv_conf: resolv_conf_str.as_deref(),
            service_cidr: Some(spec.network.service_subnet.as_str()),
            pod_cidr: Some(spec.network.pod_subnet.as_str()),
            auto_deploy_manifests: &auto_deploy,
            ports: &port_refs,
            network: k3d.network.as_deref(),
        },
    )?;

    Ok(())
}

fn resolve_auto_deploy(
    ctx: &CataContext,
    name: &str,
    spec: &ClusterSpec,
    lab_package: Option<&str>,
) -> Vec<(String, String)> {
    let mut auto_deploy: Vec<(String, String)> = spec
        .provisioner_config
        .k3d
        .auto_deploy_manifests
        .iter()
        .map(|m| (m.name.clone(), m.path.clone()))
        .collect();

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

    auto_deploy
}

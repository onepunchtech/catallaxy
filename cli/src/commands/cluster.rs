use std::fs;
use std::path::PathBuf;

use anyhow::{Result, bail};
use clap::Subcommand;
use console::style;

use crate::config::Context as CataContext;
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
        let lab = match crate::io::nix::get_lab_spec(ctx, lab_name) {
            Ok(lab) => lab,
            Err(_) => continue,
        };

        if !lab.cluster_names.iter().any(|n| n == cluster_name) {
            continue;
        }

        for (svc_name, svc) in &lab.services {
            if let Err(e) = crate::host::services::start_service(ctx, lab_name, svc_name, svc) {
                let description = svc["description"].as_str().unwrap_or(svc_name);
                println!(
                    "{} Failed to start {}: {}",
                    style("Warning:").yellow(),
                    description,
                    e
                );
            }
        }

        if let Some(port) = lab.registry_port {
            let state_dir = crate::host::state::service_state_dir(lab_name, "registry");
            if fs::create_dir_all(&state_dir).is_ok() {
                let path = state_dir.join("registries.yaml");
                let registry_yaml =
                    crate::host::services::generate_registries_yaml(port, &lab.registry_upstreams);
                if let Some(zone) = lab.dns_info.as_ref().map(|d| d.zone.as_str()) {
                    let host_dir = state_dir.join("certs.d").join(format!("registry.{zone}"));
                    if fs::create_dir_all(&host_dir).is_ok() {
                        let _ = fs::write(
                            host_dir.join("hosts.toml"),
                            crate::host::services::generate_registry_hosts_toml(zone),
                        );
                        let ca_src =
                            crate::host::state::service_state_dir(lab_name, "proxy").join("ca.crt");
                        if ca_src.exists() {
                            let _ = fs::copy(&ca_src, host_dir.join("ca.crt"));
                        }
                    }
                }
                if lab.dns_info.is_some() {
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
    let lab = crate::io::nix::get_lab_spec(ctx, &lab_name)?;
    lab.cluster(name).cloned()
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

use anyhow::Result;
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

async fn init(ctx: &CataContext, name: &str) -> Result<()> {
    io::process::check_required_tools()?;

    println!(
        "{} Initializing cluster '{name}'",
        style("catallaxy").cyan().bold()
    );

    let registries_yaml_path = crate::provision::ensure_lab_services(ctx, name);

    println!("{} Loading cluster configuration...", style(">>>").cyan());
    let spec = load_cluster_spec(ctx, name)?;

    crate::provision::provision_cluster_with_registry(
        ctx,
        name,
        &spec,
        registries_yaml_path.as_deref(),
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

    crate::apply::apply(
        ctx,
        crate::apply::ApplyRequest {
            bundle: bundle.as_deref(),
            dry_run,
            force,
            ..crate::apply::ApplyRequest::for_cluster(name)
        },
    )
    .await
}

async fn down(ctx: &CataContext, name: &str) -> Result<()> {
    println!(
        "{} Stopping cluster '{name}'",
        style("catallaxy").cyan().bold()
    );

    let spec = load_cluster_spec(ctx, name)?;
    crate::provision::deprovision_cluster(ctx, name, &spec)
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

    let cluster_name = crate::provision::provisioner_cluster_name(&spec).to_string();
    println!("{}", style("Runtime:").bold());
    match spec.provisioner {
        ProvisionerKind::K3d => {
            let docker_host = crate::provision::resolve_docker_host(ctx, &spec)?;
            if io::k3d::cluster_exists(&cluster_name, docker_host.as_deref()) {
                let _ = io::k3d::cluster_show(&cluster_name, docker_host.as_deref());
            } else {
                println!("  (not running)");
            }
        }
        ProvisionerKind::Talos => {
            let docker_host = crate::provision::resolve_docker_host(ctx, &spec)?;
            if io::talos::cluster_exists(&cluster_name, docker_host.as_deref()) {
                let _ = io::talos::cluster_show(&cluster_name, docker_host.as_deref());
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

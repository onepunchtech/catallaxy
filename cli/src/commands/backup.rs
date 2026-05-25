//! Backup and restore commands using Velero
//!
//! Provides commands for creating, listing, and restoring backups.
//! Works with both local (k3d/docker) and production clusters.

use anyhow::{Result, bail};
use chrono::Utc;
use clap::{Args, Subcommand};
use console::style;

use crate::config::Context as CataContext;
use crate::nix;
use crate::tools::velero;

#[derive(Args)]
pub struct BackupArgs {
    #[command(subcommand)]
    pub command: BackupCommands,
}

#[derive(Subcommand)]
pub enum BackupCommands {
    /// Create a new backup
    Create {
        /// Cluster name (defaults to flake fragment if provided)
        #[arg(long)]
        cluster: Option<String>,

        /// Backup name (auto-generated if not provided)
        #[arg(long)]
        name: Option<String>,

        /// Namespaces to include (comma-separated, empty = all)
        #[arg(long)]
        include_namespaces: Option<String>,

        /// Namespaces to exclude (comma-separated)
        #[arg(long, default_value = "kube-system,velero")]
        exclude_namespaces: String,

        /// Include cluster-scoped resources
        #[arg(long, default_value = "true")]
        include_cluster_resources: bool,

        /// Wait for backup to complete
        #[arg(long, default_value = "true")]
        wait: bool,
    },

    /// List backups
    List {
        /// Cluster name (defaults to flake fragment if provided)
        #[arg(long)]
        cluster: Option<String>,
    },

    /// Describe a backup
    Describe {
        /// Backup name
        name: String,

        /// Cluster name (defaults to flake fragment if provided)
        #[arg(long)]
        cluster: Option<String>,
    },

    /// View backup logs
    Logs {
        /// Backup name
        name: String,

        /// Cluster name (defaults to flake fragment if provided)
        #[arg(long)]
        cluster: Option<String>,
    },

    /// Delete a backup
    Delete {
        /// Backup name
        name: String,

        /// Cluster name (defaults to flake fragment if provided)
        #[arg(long)]
        cluster: Option<String>,
    },

    /// Restore from a backup
    Restore {
        /// Backup name to restore from
        backup: String,

        /// Cluster name (defaults to flake fragment if provided)
        #[arg(long)]
        cluster: Option<String>,

        /// Restore name (auto-generated if not provided)
        #[arg(long)]
        name: Option<String>,

        /// Namespaces to restore (comma-separated, empty = all from backup)
        #[arg(long)]
        include_namespaces: Option<String>,

        /// Wait for restore to complete
        #[arg(long, default_value = "true")]
        wait: bool,
    },

    /// List restores
    Restores {
        /// Cluster name (defaults to flake fragment if provided)
        #[arg(long)]
        cluster: Option<String>,
    },

    /// List backup schedules
    Schedules {
        /// Cluster name (defaults to flake fragment if provided)
        #[arg(long)]
        cluster: Option<String>,
    },

    /// Trigger a backup schedule manually
    Trigger {
        /// Schedule name to trigger
        schedule: String,

        /// Cluster name (defaults to flake fragment if provided)
        #[arg(long)]
        cluster: Option<String>,
    },

    /// Stabilize a local cluster (create backup before pivot or shutdown)
    Stabilize {
        /// Cluster name (defaults to flake fragment if provided)
        #[arg(long)]
        cluster: Option<String>,

        /// Backup name prefix
        #[arg(long, default_value = "stabilize")]
        prefix: String,
    },

    /// Migrate workloads between clusters (backup from source, restore to target)
    Migrate {
        /// Source cluster name
        #[arg(long)]
        from: String,

        /// Target cluster name
        #[arg(long)]
        to: String,

        /// Namespaces to migrate (comma-separated, empty = all non-system)
        #[arg(long)]
        namespaces: Option<String>,

        /// Skip confirmation prompt
        #[arg(long)]
        yes: bool,
    },
}

pub async fn run(ctx: &CataContext, args: BackupArgs) -> Result<()> {
    match args.command {
        BackupCommands::Create {
            cluster,
            name,
            include_namespaces,
            exclude_namespaces,
            include_cluster_resources,
            wait,
        } => {
            let cluster_name = ctx.resolve_cluster_name(cluster.as_deref())?;
            let kube_context = resolve_kube_context(ctx, &cluster_name)?;

            check_velero_ready(&kube_context)?;

            let backup_name = name.unwrap_or_else(|| {
                let ts = Utc::now().format("%Y%m%d-%H%M%S");
                format!("{cluster_name}-{ts}")
            });

            let include_ns: Vec<&str> = include_namespaces
                .as_ref()
                .map(|s| s.split(',').collect())
                .unwrap_or_default();

            let exclude_ns: Vec<&str> = exclude_namespaces
                .split(',')
                .filter(|s| !s.is_empty())
                .collect();

            velero::create_backup(
                ctx,
                &kube_context,
                &backup_name,
                if include_ns.is_empty() {
                    None
                } else {
                    Some(&include_ns)
                },
                if exclude_ns.is_empty() {
                    None
                } else {
                    Some(&exclude_ns)
                },
                include_cluster_resources,
                wait,
            )
        }

        BackupCommands::List { cluster } => {
            let cluster_name = ctx.resolve_cluster_name(cluster.as_deref())?;
            let kube_context = resolve_kube_context(ctx, &cluster_name)?;

            check_velero_ready(&kube_context)?;

            println!(
                "{} Backups for cluster '{cluster_name}'",
                style("catallaxy").cyan().bold()
            );
            println!();

            let output = velero::list_backups(ctx, &kube_context)?;
            println!("{output}");
            Ok(())
        }

        BackupCommands::Describe { name, cluster } => {
            let cluster_name = ctx.resolve_cluster_name(cluster.as_deref())?;
            let kube_context = resolve_kube_context(ctx, &cluster_name)?;

            check_velero_ready(&kube_context)?;

            let output = velero::describe_backup(ctx, &kube_context, &name)?;
            println!("{output}");
            Ok(())
        }

        BackupCommands::Logs { name, cluster } => {
            let cluster_name = ctx.resolve_cluster_name(cluster.as_deref())?;
            let kube_context = resolve_kube_context(ctx, &cluster_name)?;

            check_velero_ready(&kube_context)?;

            let output = velero::backup_logs(ctx, &kube_context, &name)?;
            println!("{output}");
            Ok(())
        }

        BackupCommands::Delete { name, cluster } => {
            let cluster_name = ctx.resolve_cluster_name(cluster.as_deref())?;
            let kube_context = resolve_kube_context(ctx, &cluster_name)?;

            check_velero_ready(&kube_context)?;

            velero::delete_backup(ctx, &kube_context, &name)
        }

        BackupCommands::Restore {
            backup,
            cluster,
            name,
            include_namespaces,
            wait,
        } => {
            let cluster_name = ctx.resolve_cluster_name(cluster.as_deref())?;
            let kube_context = resolve_kube_context(ctx, &cluster_name)?;

            check_velero_ready(&kube_context)?;

            let include_ns: Vec<&str> = include_namespaces
                .as_ref()
                .map(|s| s.split(',').collect())
                .unwrap_or_default();

            velero::restore(
                ctx,
                &kube_context,
                &backup,
                name.as_deref(),
                if include_ns.is_empty() {
                    None
                } else {
                    Some(&include_ns)
                },
                wait,
            )
        }

        BackupCommands::Restores { cluster } => {
            let cluster_name = ctx.resolve_cluster_name(cluster.as_deref())?;
            let kube_context = resolve_kube_context(ctx, &cluster_name)?;

            check_velero_ready(&kube_context)?;

            println!(
                "{} Restores for cluster '{cluster_name}'",
                style("catallaxy").cyan().bold()
            );
            println!();

            let output = velero::list_restores(ctx, &kube_context)?;
            println!("{output}");
            Ok(())
        }

        BackupCommands::Schedules { cluster } => {
            let cluster_name = ctx.resolve_cluster_name(cluster.as_deref())?;
            let kube_context = resolve_kube_context(ctx, &cluster_name)?;

            check_velero_ready(&kube_context)?;

            println!(
                "{} Backup schedules for cluster '{cluster_name}'",
                style("catallaxy").cyan().bold()
            );
            println!();

            let output = velero::list_schedules(ctx, &kube_context)?;
            println!("{output}");
            Ok(())
        }

        BackupCommands::Trigger { schedule, cluster } => {
            let cluster_name = ctx.resolve_cluster_name(cluster.as_deref())?;
            let kube_context = resolve_kube_context(ctx, &cluster_name)?;

            check_velero_ready(&kube_context)?;

            velero::trigger_schedule(ctx, &kube_context, &schedule)
        }

        BackupCommands::Stabilize { cluster, prefix } => {
            let cluster_name = ctx.resolve_cluster_name(cluster.as_deref())?;
            stabilize_cluster(ctx, &cluster_name, &prefix).await
        }

        BackupCommands::Migrate {
            from,
            to,
            namespaces,
            yes,
        } => migrate_cluster(ctx, &from, &to, namespaces, yes).await,
    }
}

/// Resolve the Kubernetes context for a cluster
fn resolve_kube_context(ctx: &CataContext, cluster_name: &str) -> Result<String> {
    let config = nix::get_cluster_config(ctx, cluster_name)?;

    let k3d_enabled = config
        .pointer("/provisioner/k3d/enable")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    let default_name = format!("catallaxy-{cluster_name}");

    if k3d_enabled {
        let k3d_name = config
            .pointer("/provisioner/k3d/clusterName")
            .and_then(|v| v.as_str())
            .unwrap_or(&default_name);
        Ok(format!("k3d-{k3d_name}"))
    } else {
        let provider = config["provider"].as_str().unwrap_or("unknown");
        match provider {
            "docker" => Ok(format!("admin@{default_name}")),
            _ => Ok(cluster_name.to_string()),
        }
    }
}

/// Check that Velero is installed and ready
fn check_velero_ready(kube_context: &str) -> Result<()> {
    if !velero::is_ready(kube_context) {
        bail!(
            "Velero is not installed or not ready in cluster.\n\
             Enable it with: components.velero.enable = true\n\
             Then run: cata apply <cluster>"
        );
    }
    Ok(())
}

/// Stabilize a local cluster by creating a full backup
///
/// This is useful before:
/// - Pivoting CAPI resources to a new cluster
/// - Shutting down a local development cluster
/// - Upgrading cluster components
async fn stabilize_cluster(ctx: &CataContext, cluster_name: &str, prefix: &str) -> Result<()> {
    println!(
        "{} Stabilizing cluster '{cluster_name}'",
        style("catallaxy").cyan().bold()
    );
    println!();

    let config = nix::get_cluster_config(ctx, cluster_name)?;
    let kube_context = resolve_kube_context(ctx, cluster_name)?;

    // Check if velero is enabled
    let velero_enabled = config
        .pointer("/components/velero/enable")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    if !velero_enabled {
        println!(
            "{} Velero is not enabled for this cluster.",
            style("Note:").yellow()
        );
        println!("       Enable it with: components.velero.enable = true");
        println!("       For local clusters, also set: components.velero.local.enable = true");
        println!();
        println!("       Then run: cata apply {cluster_name}");
        return Ok(());
    }

    // Check if velero is ready
    if !velero::is_ready(&kube_context) {
        println!(
            "{} Velero is enabled but not ready. Deploying...",
            style(">>>").cyan()
        );

        // Deploy velero via apply
        crate::commands::apply::run(
            ctx,
            crate::commands::apply::ApplyArgs {
                cluster: Some(cluster_name.to_string()),
                phase: Some("operators".to_string()),
                component: Some("velero".to_string()),
                dry_run: false,
                sequential: false,
                manifests_dir: None,
            },
        )
        .await?;

        // Wait for velero to be ready
        println!("{} Waiting for Velero to be ready...", style(">>>").cyan());
        for _ in 0..60 {
            if velero::is_ready(&kube_context) {
                break;
            }
            tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
        }

        if !velero::is_ready(&kube_context) {
            bail!("Velero failed to become ready after deployment");
        }
    }

    // Create a full backup
    let ts = Utc::now().format("%Y%m%d-%H%M%S");
    let backup_name = format!("{prefix}-{cluster_name}-{ts}");

    println!(
        "{} Creating stabilization backup '{backup_name}'...",
        style(">>>").cyan()
    );

    let exclude_ns = vec!["kube-system", "velero", "local-path-storage"];

    velero::create_backup(
        ctx,
        &kube_context,
        &backup_name,
        None,              // include all namespaces
        Some(&exclude_ns), // exclude system namespaces
        true,              // include cluster resources
        true,              // wait for completion
    )?;

    println!();
    println!(
        "{} Cluster '{cluster_name}' stabilized successfully!",
        style(">>>").green()
    );
    println!();
    println!("  Backup: {backup_name}");
    println!();
    println!("  To restore later:");
    println!("    cata backup restore {backup_name} --cluster {cluster_name}");

    Ok(())
}

/// Migrate workloads between clusters using Velero backup + restore.
///
/// Flow:
/// 1. Create a backup on the source cluster
/// 2. Ensure the target cluster has Velero with access to the same backup storage
/// 3. Restore the backup on the target cluster
///
/// Both clusters must have Velero configured with a shared backup storage location
/// (e.g., same S3 bucket, same SeaweedFS instance).
async fn migrate_cluster(
    ctx: &CataContext,
    from: &str,
    to: &str,
    namespaces: Option<String>,
    skip_confirm: bool,
) -> Result<()> {
    println!(
        "{} Migrating workloads: {} → {}",
        style("catallaxy").cyan().bold(),
        from,
        to
    );
    println!();

    let from_context = resolve_kube_context(ctx, from)?;
    let to_context = resolve_kube_context(ctx, to)?;

    // Check Velero is ready on both clusters
    check_velero_ready(&from_context)?;
    check_velero_ready(&to_context)?;

    let ns_list: Vec<&str> = namespaces
        .as_ref()
        .map(|s| s.split(',').collect())
        .unwrap_or_default();

    let ns_display = if ns_list.is_empty() {
        "all (excluding kube-system, velero)".to_string()
    } else {
        ns_list.join(", ")
    };

    println!("  Source:     {} (context: {})", from, from_context);
    println!("  Target:     {} (context: {})", to, to_context);
    println!("  Namespaces: {}", ns_display);
    println!();

    if !skip_confirm {
        println!(
            "{} This will restore workloads on the target cluster.",
            style("Warning:").yellow()
        );
        println!("  Existing resources with the same names will be overwritten.");
        println!();
        print!("  Continue? [y/N] ");
        std::io::Write::flush(&mut std::io::stdout())?;

        let mut input = String::new();
        std::io::stdin().read_line(&mut input)?;
        if !input.trim().eq_ignore_ascii_case("y") {
            println!("{} Migration cancelled.", style(">>>").yellow());
            return Ok(());
        }
    }

    // Step 1: Create backup on source
    let ts = Utc::now().format("%Y%m%d-%H%M%S");
    let backup_name = format!("migrate-{from}-to-{to}-{ts}");

    println!();
    println!(
        "{} Creating backup on source cluster '{from}'...",
        style(">>>").cyan()
    );

    let exclude_ns = vec!["kube-system", "velero", "local-path-storage"];

    velero::create_backup(
        ctx,
        &from_context,
        &backup_name,
        if ns_list.is_empty() {
            None
        } else {
            Some(&ns_list)
        },
        if ns_list.is_empty() {
            Some(&exclude_ns)
        } else {
            None
        },
        true, // include cluster resources
        true, // wait
    )?;

    println!(
        "{} Backup '{}' created on source cluster",
        style(">>>").green(),
        backup_name
    );

    // Step 2: Restore on target
    println!();
    println!(
        "{} Restoring backup on target cluster '{to}'...",
        style(">>>").cyan()
    );

    velero::restore(
        ctx,
        &to_context,
        &backup_name,
        None, // auto-generate restore name
        if ns_list.is_empty() {
            None
        } else {
            Some(&ns_list)
        },
        true, // wait
    )?;

    println!();
    println!(
        "{} Migration complete: {} → {}",
        style(">>>").green(),
        from,
        to
    );
    println!();
    println!("  Backup used: {backup_name}");
    println!();
    println!("  Next steps:");
    println!(
        "    - Verify workloads on target: kubectl --context {} get pods -A",
        to_context
    );
    println!("    - Update DNS/ingress to point to new cluster");
    println!("    - When satisfied, decommission source cluster");

    Ok(())
}

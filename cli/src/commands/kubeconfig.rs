use std::fs;

use anyhow::{Context, Result};
use clap::Subcommand;
use console::style;

use crate::config::Context as CataContext;
use crate::domain::LabSpec;
use crate::io;

#[derive(Subcommand)]
pub enum KubeconfigCommands {
    #[command(about = "Show the kubeconfig contexts for the lab's clusters")]
    Show,
}

pub async fn run(ctx: &CataContext, command: KubeconfigCommands) -> Result<()> {
    match command {
        KubeconfigCommands::Show => show(ctx).await,
    }
}

async fn show(ctx: &CataContext) -> Result<()> {
    let name = ctx
        .flake_ref
        .fragment
        .as_deref()
        .ok_or_else(|| anyhow::anyhow!("No lab specified. Use --flake <ref>#<lab>"))?;

    let lab = crate::io::nix::get_lab_config(ctx, name)?;

    println!(
        "{} Kubeconfig contexts for lab '{name}'",
        style("catallaxy").cyan().bold()
    );
    println!();

    let lab = LabSpec::from_value(lab).context("parsing the lab configuration")?;

    for cluster_name in &lab.cluster_names {
        let context = lab.kube_context(cluster_name)?;
        let status = if io::kubectl::api_reachable(context) {
            style("reachable").green()
        } else {
            style("not reachable").yellow()
        };
        println!(
            "  {} → {} [{}]",
            style(cluster_name).cyan(),
            context,
            status
        );
    }

    Ok(())
}

pub fn cleanup_kubeconfig(_ctx: &CataContext, cluster_name: &str) -> Result<()> {
    let kubeconfig_path = dirs::home_dir()
        .context("Could not find home directory")?
        .join(".kube")
        .join(format!("{}.kubeconfig", cluster_name));

    if kubeconfig_path.exists() {
        fs::remove_file(&kubeconfig_path)
            .with_context(|| format!("Failed to remove {}", kubeconfig_path.display()))?;
        println!(
            "{} Removed {}",
            style(">>>").green(),
            kubeconfig_path.display()
        );
    }

    io::kubectl::delete_kubeconfig_context(&format!("{}-admin@{}", cluster_name, cluster_name))?;
    io::kubectl::delete_kubeconfig_context(cluster_name)?;

    io::kubectl::delete_kubeconfig_cluster(cluster_name)?;
    io::kubectl::delete_kubeconfig_user(&format!("{}-admin", cluster_name))?;

    Ok(())
}

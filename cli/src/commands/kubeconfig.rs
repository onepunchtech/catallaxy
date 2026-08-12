use std::fs;

use anyhow::{Context, Result};
use clap::Subcommand;
use console::style;

use crate::config::Context as CataContext;
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

    if let Some(clusters) = lab["clusterNames"].as_array() {
        for cluster_name in clusters {
            let cluster_name = cluster_name.as_str().unwrap_or("?");
            if let Ok(config) = crate::io::nix::get_cluster_config(ctx, cluster_name) {
                let context = resolve_kube_context(&config, cluster_name);
                let reachable = io::kubectl::api_reachable(&context);
                let status = if reachable {
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
        }
    }

    Ok(())
}

fn resolve_kube_context(config: &serde_json::Value, cluster_name: &str) -> String {
    let is_k3d = config["provisioner"].as_str().unwrap_or("k3d") == "k3d";

    let default_name = format!("catallaxy-{cluster_name}");

    if is_k3d {
        let k3d_name = config
            .pointer("/provisionerConfig/k3d/clusterName")
            .and_then(|v| v.as_str())
            .unwrap_or(&default_name);
        format!("k3d-{k3d_name}")
    } else {
        cluster_name.to_string()
    }
}

pub fn cleanup_kubeconfig(ctx: &CataContext, cluster_name: &str) -> Result<()> {
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

    io::kubectl::delete_kubeconfig_context(
        ctx,
        &format!("{}-admin@{}", cluster_name, cluster_name),
    )?;
    io::kubectl::delete_kubeconfig_context(ctx, cluster_name)?;

    io::kubectl::delete_kubeconfig_cluster(ctx, cluster_name)?;
    io::kubectl::delete_kubeconfig_user(ctx, &format!("{}-admin", cluster_name))?;

    Ok(())
}

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

pub fn run(ctx: &CataContext, command: KubeconfigCommands) -> Result<()> {
    match command {
        KubeconfigCommands::Show => show(ctx),
    }
}

fn show(ctx: &CataContext) -> Result<()> {
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

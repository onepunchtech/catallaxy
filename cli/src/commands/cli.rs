use clap::{Parser, Subcommand};

use crate::commands::{apply, cluster, diagnose, images, kubeconfig, lab, pki, secrets};
use crate::config::Context as CataContext;

#[derive(Parser)]
#[command(name = "cata")]
#[command(author, version, about, long_about = None)]
#[command(propagate_version = true)]
pub struct Cli {
    #[arg(
        long,
        env = "CATALLAXY_FLAKE",
        default_value = ".",
        value_name = "REF",
        help = "Flake to evaluate, as <ref>#<name>"
    )]
    pub flake: String,

    #[arg(short, long, global = true, help = "Verbose output")]
    pub verbose: bool,

    #[command(subcommand)]
    pub command: Commands,
}

#[derive(Subcommand)]
pub enum Commands {
    #[command(about = "Per-cluster operations, for when you do not want the whole lab")]
    Cluster {
        #[command(subcommand)]
        command: cluster::ClusterCommands,
    },

    #[command(about = "Lab-level operations")]
    Lab {
        #[command(subcommand)]
        command: lab::LabCommands,
    },

    #[command(about = "Apply manifests to one cluster")]
    Apply(apply::ApplyArgs),

    #[command(about = "Show pods, events and deployments for a cluster")]
    Diagnose(diagnose::DiagnoseArgs),

    #[command(about = "Client certificates for cluster access, optionally on a YubiKey")]
    Pki {
        #[command(subcommand)]
        command: pki::PkiCommands,
    },

    #[command(about = "Manage the encrypted secret stores")]
    Secrets {
        #[command(subcommand)]
        command: secrets::SecretsCommands,
    },

    #[command(about = "Inspect kubeconfig contexts for lab clusters")]
    Kubeconfig {
        #[command(subcommand)]
        command: kubeconfig::KubeconfigCommands,
    },

    #[command(about = "Inspect and mirror the container images a lab references")]
    Images {
        #[command(subcommand)]
        command: images::ImagesCommands,
    },
}

pub async fn dispatch(ctx: &CataContext, command: Commands) -> anyhow::Result<()> {
    match command {
        Commands::Cluster { command } => cluster::run(ctx, command).await,
        Commands::Lab { command } => lab::run(ctx, command).await,
        Commands::Apply(args) => apply::run(ctx, args).await,
        Commands::Diagnose(args) => diagnose::run(ctx, args).await,
        Commands::Pki { command } => pki::run(ctx, command).await,
        Commands::Secrets { command } => secrets::run(ctx, command).await,
        Commands::Kubeconfig { command } => kubeconfig::run(ctx, command).await,
        Commands::Images { command } => images::run(ctx, command).await,
    }
}

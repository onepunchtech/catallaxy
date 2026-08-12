use clap::{CommandFactory, Parser, Subcommand};
use std::process::ExitCode;

use cata::commands::{
    apply, cluster, diagnose, docs, generate, images, kubeconfig, lab, pki, secrets,
};
use cata::config;

#[derive(Parser)]
#[command(name = "cata")]
#[command(author, version, about, long_about = None)]
#[command(propagate_version = true)]
struct Cli {
    #[arg(
        long,
        env = "CATALLAXY_FLAKE",
        default_value = ".",
        value_name = "REF",
        help = "Flake to evaluate, as <ref>#<name>"
    )]
    flake: String,

    #[arg(short, long, global = true, help = "Verbose output")]
    verbose: bool,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
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

    #[command(about = "Render the documentation sources")]
    Docs {
        #[command(subcommand)]
        command: docs::DocsCommands,
    },

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

    #[command(about = "Regenerate Kubernetes API types from OpenAPI specs and CRDs")]
    Generate(generate::GenerateArgs),
}

#[tokio::main]
async fn main() -> ExitCode {
    let cli = Cli::parse();

    let result = run(cli).await;

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e:#}");
            ExitCode::FAILURE
        }
    }
}

async fn run(cli: Cli) -> anyhow::Result<()> {
    let ctx = config::Context::new(cli.flake, cli.verbose)?;

    match cli.command {
        Commands::Cluster { command } => cluster::run(&ctx, command).await,
        Commands::Lab { command } => lab::run(&ctx, command).await,
        Commands::Apply(args) => apply::run(&ctx, args).await,
        Commands::Diagnose(args) => diagnose::run(&ctx, args).await,
        Commands::Docs { command } => docs::run(command, Cli::command()),
        Commands::Pki { command } => pki::run(&ctx, command).await,
        Commands::Secrets { command } => secrets::run(&ctx, command).await,
        Commands::Kubeconfig { command } => kubeconfig::run(&ctx, command).await,
        Commands::Images { command } => images::run(&ctx, command).await,
        Commands::Generate(args) => generate::run(&ctx, args).await,
    }
}

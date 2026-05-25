//! cata - CLI for catallaxy platform management
//!
//! This CLI orchestrates Kubernetes cluster lifecycle through Nix-defined
//! configurations. It evaluates flake outputs to get cluster configuration and
//! orchestrates external tools (talosctl, kubectl, kapp, helm).

mod codegen;
mod commands;
mod config;
mod generators;
mod lint;
mod nix;
mod tools;

use clap::{Parser, Subcommand};
use std::process::ExitCode;

use commands::{apply, backup, bootstrap, cluster, generate, kubeconfig, lab, pki, secrets};

/// Catallaxy - Declarative Kubernetes Platform Management
#[derive(Parser)]
#[command(name = "cata")]
#[command(author, version, about, long_about = None)]
#[command(propagate_version = true)]
struct Cli {
    /// Flake reference (path, URL, or ref#name)
    #[arg(long, env = "CATALLAXY_FLAKE", default_value = ".")]
    flake: String,

    /// Verbose output
    #[arg(short, long, global = true)]
    verbose: bool,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Manage clusters
    Cluster {
        #[command(subcommand)]
        command: cluster::ClusterCommands,
    },

    /// Manage labs (multi-cluster environments)
    Lab {
        #[command(subcommand)]
        command: lab::LabCommands,
    },

    /// Apply manifests to a cluster
    Apply(apply::ApplyArgs),

    /// Backup and restore cluster state
    Backup(backup::BackupArgs),

    /// Bootstrap a CAPI management cluster
    Bootstrap(bootstrap::BootstrapArgs),

    /// Manage PKI certificates and YubiKey provisioning
    Pki {
        #[command(subcommand)]
        command: pki::PkiCommands,
    },

    /// Manage secrets
    Secrets {
        #[command(subcommand)]
        command: secrets::SecretsCommands,
    },

    /// Sync kubeconfigs for CAPI-managed workload clusters
    Kubeconfig {
        #[command(subcommand)]
        command: kubeconfig::KubeconfigCommands,
    },

    /// Generate Kubernetes API types from packaged OpenAPI specs and CRDs
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
        Commands::Backup(args) => backup::run(&ctx, args).await,
        Commands::Bootstrap(args) => bootstrap::run(&ctx, args).await,
        Commands::Pki { command } => pki::run(&ctx, command).await,
        Commands::Secrets { command } => secrets::run(&ctx, command).await,
        Commands::Kubeconfig { command } => kubeconfig::run(&ctx, command).await,
        Commands::Generate(args) => generate::run(&ctx, args).await,
    }
}

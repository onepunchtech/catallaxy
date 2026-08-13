use clap::{CommandFactory, Parser, Subcommand};
use std::process::ExitCode;

use cata::commands::{docs, generate};
use cata::config;

#[derive(Parser)]
#[command(name = "cata-build")]
#[command(
    author,
    version,
    about = "Build-time tooling for the catallaxy repository itself"
)]
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
    #[command(about = "Render the documentation sources")]
    Docs {
        #[command(subcommand)]
        command: docs::DocsCommands,
    },

    #[command(about = "Regenerate Kubernetes API types from OpenAPI specs and CRDs")]
    Generate(generate::GenerateArgs),
}

#[tokio::main]
async fn main() -> ExitCode {
    let cli = Cli::parse();

    match run(cli).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e:#}");
            ExitCode::FAILURE
        }
    }
}

async fn run(cli: Cli) -> anyhow::Result<()> {
    cata::io::process::set_verbose(cli.verbose);

    let ctx = config::Context::new(cli.flake, cli.verbose)?;

    match cli.command {
        Commands::Docs { command } => docs::run(command, cata::commands::cli::Cli::command()),
        Commands::Generate(args) => generate::run(&ctx, args).await,
    }
}

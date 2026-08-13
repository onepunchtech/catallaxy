use clap::Parser;
use std::process::ExitCode;

use cata::commands::cli::{Cli, dispatch};
use cata::config;

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

    dispatch(&ctx, cli.command).await
}

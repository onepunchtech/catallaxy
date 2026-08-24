use clap::Parser;
use std::process::ExitCode;

use cata::commands::cli::{Cli, dispatch};
use cata::config;

#[tokio::main]
async fn main() -> ExitCode {
    let cli = Cli::parse();

    tokio::spawn(async {
        if tokio::signal::ctrl_c().await.is_ok() {
            cata::io::fs::erase_secure_tempdirs();
            eprintln!();
            eprintln!("interrupted; erased any decrypted secrets from the temp directory");
            std::process::exit(130);
        }
    });

    let code = match run(cli).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => match e.downcast_ref::<cata::domain::ExitWith>() {
            Some(exit) => ExitCode::from(exit.code()),
            None => {
                eprintln!("{e:#}");
                ExitCode::FAILURE
            }
        },
    };

    cata::io::fs::erase_secure_tempdirs();
    code
}

async fn run(cli: Cli) -> anyhow::Result<()> {
    cata::io::process::set_verbose(cli.verbose);

    let ctx = config::Context::new(cli.flake, cli.verbose)?;

    dispatch(&ctx, cli.command).await
}

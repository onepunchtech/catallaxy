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
        global = true,
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
        Commands::Cluster { command } => cluster::run(ctx, command),
        Commands::Lab { command } => lab::run(ctx, command).await,
        Commands::Apply(args) => apply::run(ctx, args),
        Commands::Diagnose(args) => diagnose::run(ctx, args),
        Commands::Pki { command } => pki::run(ctx, command),
        Commands::Secrets { command } => secrets::run(ctx, command),
        Commands::Kubeconfig { command } => kubeconfig::run(ctx, command),
        Commands::Images { command } => images::run(ctx, command).await,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::secrets::{SecretsSpec, describe_store_problems, validate_store};
    use clap::CommandFactory;

    fn parses(argv: &[&str]) -> bool {
        Cli::command().try_get_matches_from(argv).is_ok()
    }

    fn strip_trailing_comment(line: &str) -> &str {
        let bytes = line.as_bytes();
        match (1..bytes.len()).find(|&i| bytes[i] == b'#' && bytes[i - 1] == b' ') {
            Some(i) => &line[..i],
            None => line,
        }
    }

    fn suggested_commands(text: &str) -> Vec<String> {
        text.lines()
            .map(str::trim)
            .filter(|l| l.starts_with("cata "))
            .map(|l| strip_trailing_comment(l).trim().to_string())
            .collect()
    }

    #[test]
    fn every_command_the_secrets_error_suggests_actually_parses() {
        let spec: SecretsSpec = serde_json::from_value(serde_json::json!({
            "stores": { "trust": { "backend": "sops" } },
            "managed": { "lab-ca": { "store": "trust", "keys": { "ca.crt": {} } } }
        }))
        .expect("fixture spec");

        let problems = validate_store(&spec, "trust", &Default::default());
        let msg = describe_store_problems(&spec, "mesh.local", "trust", &problems);

        let suggestions = suggested_commands(&msg);
        assert!(!suggestions.is_empty(), "no suggestions found in:\n{msg}");

        for suggestion in suggestions {
            let argv: Vec<&str> = suggestion.split_whitespace().collect();
            assert!(
                parses(&argv),
                "the CLI told the user to run `{suggestion}`, which its own parser rejects"
            );
        }
    }

    #[test]
    fn flake_is_global_so_it_can_follow_the_subcommand() {
        assert!(parses(&[
            "cata",
            "--flake",
            ".#minimal.local",
            "lab",
            "plan"
        ]));
        assert!(parses(&[
            "cata",
            "lab",
            "plan",
            "--flake",
            ".#minimal.local"
        ]));
    }
}

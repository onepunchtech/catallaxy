use std::path::PathBuf;

use anyhow::Result;
use clap::Subcommand;

use crate::config::Context as CataContext;

pub mod apply;
pub mod destroy;
mod display;
pub mod dns;
pub mod down;
pub mod env;
mod lint_cmd;
mod ops;
pub mod plan;
pub mod plan_manifests;
pub mod publish;
pub mod up;
pub mod verify;

const LAB_NAME_HELP: &str = "Lab to act on. Defaults to the flake fragment";
const STABLE_HELP: &str =
    "Deterministic snapshot text: no colour, no emoji, no descriptions, store hashes normalized";
const FROM_FILE_HELP: &str = "Read plan JSON from a file instead of evaluating";
const DIFF_HELP: &str =
    "Diff the stable output against a baseline, exiting non-zero on mismatch. Implies --stable";
const FORCE_APPLY_HELP: &str = "Apply directly even when the cluster's deploy strategy is GitOps";

#[derive(Subcommand)]
pub enum LabCommands {
    #[command(about = "List every lab this flake defines, with cluster counts")]
    List,

    #[command(about = "Show the current state of clusters and host services")]
    Status {
        #[arg(help = LAB_NAME_HELP)]
        name: Option<String>,
        #[arg(long, help = "Emit the state as JSON instead of a table")]
        json: bool,
    },

    #[command(about = "Run the deploy plan")]
    Up {
        #[arg(help = LAB_NAME_HELP)]
        name: Option<String>,

        #[arg(long, help = "Print what would happen without doing it")]
        dry_run: bool,

        #[arg(
            long,
            value_name = "KIND",
            help = "Stop after the last step of this kind"
        )]
        up_to: Option<String>,
    },

    #[command(about = "Stop clusters, preserving state. Restartable with 'lab up'")]
    Down {
        #[arg(help = LAB_NAME_HELP)]
        name: Option<String>,
    },

    #[command(about = "Run the teardown plan: clusters, cloud resources, services, network")]
    Destroy {
        #[arg(help = LAB_NAME_HELP)]
        name: Option<String>,
    },

    #[command(about = "Show the ordered deploy plan")]
    Plan {
        #[arg(help = LAB_NAME_HELP)]
        name: Option<String>,

        #[arg(long, help = "Show the teardown plan instead of the deploy plan")]
        teardown: bool,

        #[arg(long, help = STABLE_HELP)]
        stable: bool,

        #[arg(long, value_name = "PATH", help = FROM_FILE_HELP)]
        from_file: Option<std::path::PathBuf>,

        #[arg(long, value_name = "PATH", help = DIFF_HELP)]
        diff: Option<std::path::PathBuf>,
    },

    #[command(about = "Show the install-wave layout for a cluster")]
    PlanManifests {
        #[arg(help = LAB_NAME_HELP)]
        name: Option<String>,

        #[arg(long, value_name = "NAME", help = "Cluster to lay out")]
        cluster: Option<String>,

        #[arg(long, help = STABLE_HELP)]
        stable: bool,

        #[arg(long, value_name = "PATH", help = FROM_FILE_HELP)]
        from_file: Option<std::path::PathBuf>,

        #[arg(long, value_name = "PATH", help = DIFF_HELP)]
        diff: Option<std::path::PathBuf>,
    },

    #[command(about = "Apply manifests to existing clusters, without the provisioning steps")]
    Apply {
        #[arg(help = LAB_NAME_HELP)]
        name: Option<String>,

        #[arg(long, help = "Apply only this bundle")]
        bundle: Option<String>,

        #[arg(long, help = "Print what would happen without doing it")]
        dry_run: bool,

        #[arg(long, help = FORCE_APPLY_HELP)]
        force: bool,
    },

    #[command(about = "Check a running lab against what it declares")]
    Verify {
        #[arg(help = LAB_NAME_HELP)]
        name: Option<String>,
        #[arg(
            long,
            value_name = "CHECK",
            help = "Run only this check: clusters, services, rollouts, endpoints or declared"
        )]
        check: Option<String>,
        #[arg(long, help = "Emit diagnostics as JSON instead of a report")]
        json: bool,
    },

    #[command(about = "Run environment, configuration and rendered-manifest checks")]
    Lint {
        #[arg(help = LAB_NAME_HELP)]
        name: Option<String>,
        #[arg(long, help = "Lint an already-built package instead of evaluating")]
        path: Option<PathBuf>,
        #[arg(
            long,
            value_delimiter = ',',
            value_name = "RULES",
            help = "Comma-separated rule names to skip"
        )]
        skip: Vec<String>,
    },

    #[command(about = "Push rendered manifests to a git repository")]
    Publish {
        #[arg(help = LAB_NAME_HELP)]
        name: Option<String>,
        #[arg(long, help = "Open a pull request instead of pushing to the branch")]
        pr: bool,
        #[arg(long, value_name = "MSG", help = "Commit message")]
        message: Option<String>,
        #[arg(long, help = "Print what would be published without pushing")]
        dry_run: bool,
    },

    #[command(
        trailing_var_arg = true,
        about = "Run a lab-declared ops command. Arguments after '--' are passed through"
    )]
    Ops {
        #[arg(long, help = LAB_NAME_HELP)]
        name: Option<String>,
        #[arg(
            trailing_var_arg = true,
            allow_hyphen_values = true,
            help = "Ops command and its arguments"
        )]
        args: Vec<String>,
    },

    #[command(about = "Configure host DNS for the lab zone")]
    Dns {
        #[arg(help = LAB_NAME_HELP)]
        name: Option<String>,
        #[arg(long, help = "Install the resolver configuration")]
        setup: bool,
        #[arg(long, help = "Remove the resolver configuration")]
        teardown: bool,
    },

    #[command(about = "Show clusters, services and network")]
    Topology {
        #[arg(help = LAB_NAME_HELP)]
        name: Option<String>,

        #[arg(
            long,
            short,
            default_value = "table",
            value_name = "FORMAT",
            help = "table, json, mermaid or dot"
        )]
        format: String,

        #[arg(long, help = "Query the clusters for real status instead of [unknown]")]
        live: bool,
    },

    #[command(about = "Print shell exports that trust the lab CA in the current shell")]
    Env {
        #[arg(env = "CATALLAXY_LAB", help = LAB_NAME_HELP)]
        name: Option<String>,

        #[arg(
            long,
            value_enum,
            default_value = "posix",
            help = "Output syntax for the exports"
        )]
        shell: env::Shell,

        #[arg(long, help = "Print statements that clear the exports instead")]
        unset: bool,
    },
}

pub async fn run(ctx: &CataContext, command: LabCommands) -> Result<()> {
    match command {
        LabCommands::List => display::list(ctx).await,
        LabCommands::Status { name, json } => {
            let name = ctx.resolve_lab_name(name.as_deref())?;
            display::status(ctx, &name, json).await
        }
        LabCommands::Verify { name, check, json } => verify::run(ctx, name, check, json).await,
        LabCommands::Up {
            name,
            dry_run,
            up_to,
        } => {
            let name = ctx.resolve_lab_name(name.as_deref())?;
            up::run(ctx, &name, dry_run, up_to).await
        }
        LabCommands::Apply {
            name,
            bundle,
            dry_run,
            force,
        } => {
            let name = ctx.resolve_lab_name(name.as_deref())?;
            apply::run(ctx, &name, bundle, dry_run, force).await
        }
        LabCommands::Plan {
            name,
            teardown,
            stable,
            from_file,
            diff,
        } => {
            let resolved = if from_file.is_some() {
                name.clone()
            } else {
                Some(ctx.resolve_lab_name(name.as_deref())?)
            };
            plan::run(ctx, resolved.as_deref(), teardown, stable, from_file, diff).await
        }
        LabCommands::PlanManifests {
            name,
            cluster,
            stable,
            from_file,
            diff,
        } => {
            let resolved = if from_file.is_some() {
                name.clone()
            } else {
                Some(ctx.resolve_lab_name(name.as_deref())?)
            };
            plan_manifests::run(
                ctx,
                resolved.as_deref(),
                cluster.as_deref(),
                stable,
                from_file,
                diff,
            )
            .await
        }
        LabCommands::Down { name } => {
            let name = ctx.resolve_lab_name(name.as_deref())?;
            down::run(ctx, &name).await
        }
        LabCommands::Destroy { name } => {
            let name = ctx.resolve_lab_name(name.as_deref())?;
            destroy::run(ctx, &name).await
        }
        other => run_tooling(ctx, other).await,
    }
}

async fn run_tooling(ctx: &CataContext, command: LabCommands) -> Result<()> {
    match command {
        LabCommands::Lint { name, path, skip } => lint_cmd::run(ctx, name, path, skip).await,
        LabCommands::Publish {
            name,
            pr,
            message,
            dry_run,
        } => {
            let name = ctx.resolve_lab_name(name.as_deref())?;
            publish::publish(ctx, &name, pr, message, dry_run).await
        }
        LabCommands::Ops { name, args } => {
            let name = ctx.resolve_lab_name(name.as_deref())?;
            ops::ops(ctx, &name, &args).await
        }
        LabCommands::Env { name, shell, unset } => {
            let name = ctx.resolve_lab_name(name.as_deref())?;
            env::env(&name, shell, unset)
        }
        LabCommands::Dns {
            name,
            setup,
            teardown,
        } => {
            let name = ctx.resolve_lab_name(name.as_deref())?;
            dns::dns(ctx, &name, setup, teardown).await
        }
        LabCommands::Topology { name, format, live } => {
            let name = ctx.resolve_lab_name(name.as_deref())?;
            display::topology_cmd(ctx, &name, &format, live).await
        }
        _ => unreachable!("lifecycle commands are handled by run"),
    }
}

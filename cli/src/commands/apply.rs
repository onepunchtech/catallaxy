use anyhow::Result;
use clap::Args;

use crate::apply::ApplyRequest;
use crate::config::Context as CataContext;

#[derive(Args)]
pub struct ApplyArgs {
    #[arg(help = "Cluster to apply to. Defaults to the flake fragment")]
    pub cluster: Option<String>,

    #[arg(long, help = "Apply only this bundle")]
    pub bundle: Option<String>,

    #[arg(long, help = "Print what would happen without doing it")]
    pub dry_run: bool,

    #[arg(
        long,
        help = "Apply directly even when the cluster's deploy strategy is GitOps"
    )]
    pub force: bool,
}

pub fn run(ctx: &CataContext, args: ApplyArgs) -> Result<()> {
    crate::apply::apply(
        ctx,
        ApplyRequest {
            cluster: args.cluster.as_deref(),
            bundle: args.bundle.as_deref(),
            dry_run: args.dry_run,
            force: args.force,
            manifests_dir: None,
            secrets_cache: None,
            lab: None,
            kube_context_override: None,
        },
    )
}

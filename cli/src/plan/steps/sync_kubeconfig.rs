use anyhow::Result;
use console::style;

use crate::commands::lab::state::resolve_cluster_context;
use crate::plan::StepContext;

pub fn run(
    sctx: &StepContext<'_>,
    target: &str,
    clusters: &[String],
    kube_context_override: Option<&str>,
) -> Result<()> {
    let context = kube_context_override
        .map(String::from)
        .unwrap_or_else(|| resolve_cluster_context(sctx.lab, target));
    for cluster_name in clusters {
        println!(
            "{} Syncing kubeconfig for '{cluster_name}'...",
            style(">>>").cyan()
        );
        match crate::commands::lab::orchestrate::sync_crossplane_kubeconfig(&context, cluster_name)
        {
            Ok(()) => println!(
                "{} Kubeconfig synced for '{cluster_name}'",
                style(">>>").green(),
            ),
            Err(e) => println!(
                "{} Failed to sync kubeconfig for '{cluster_name}': {e}",
                style("Warning:").yellow(),
            ),
        }
    }
    Ok(())
}

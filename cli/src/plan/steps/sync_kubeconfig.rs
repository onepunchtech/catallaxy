use anyhow::Result;
use console::style;

use crate::plan::StepContext;

pub fn run(
    sctx: &StepContext<'_>,
    target: &str,
    clusters: &[String],
    kube_context_override: Option<&str>,
) -> Result<()> {
    let context = kube_context_override
        .map(String::from)
        .map(Ok)
        .unwrap_or_else(|| sctx.lab.kube_context(target).map(String::from))?;
    for cluster_name in clusters {
        println!(
            "{} Syncing kubeconfig for '{cluster_name}'...",
            style(">>>").cyan()
        );
        match crate::crossplane::sync_kubeconfig(sctx.ctx, &context, cluster_name) {
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

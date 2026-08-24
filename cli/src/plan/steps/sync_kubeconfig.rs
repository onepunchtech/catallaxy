use anyhow::{Context, Result};
use console::style;

use crate::domain::plan::SyncKubeconfigParams;
use crate::plan::StepContext;

pub fn run(sctx: &StepContext<'_>, p: &SyncKubeconfigParams) -> Result<()> {
    let SyncKubeconfigParams {
        target,
        clusters,
        kube_context: kube_context_override,
    } = p;
    let kube_context_override = kube_context_override.as_deref();

    let context = kube_context_override
        .map(String::from)
        .map(Ok)
        .unwrap_or_else(|| sctx.lab.kube_context(target).map(String::from))?;
    for cluster_name in clusters {
        println!(
            "{} Syncing kubeconfig for '{cluster_name}'...",
            style(">>>").cyan()
        );
        crate::crossplane::sync_kubeconfig(&context, cluster_name).with_context(|| {
            format!(
                "could not sync the kubeconfig for '{cluster_name}'. Every later \
                 step addresses that cluster through the context this writes, so \
                 continuing would target a stale cluster or none at all"
            )
        })?;
        println!(
            "{} Kubeconfig synced for '{cluster_name}'",
            style(">>>").green(),
        );
    }
    Ok(())
}

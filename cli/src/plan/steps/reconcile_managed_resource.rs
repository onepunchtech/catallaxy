use anyhow::Result;

use crate::domain::plan::ReconcileManagedResourceParams;
use crate::plan::StepContext;

pub fn run(sctx: &StepContext<'_>, p: &ReconcileManagedResourceParams) -> Result<()> {
    let ReconcileManagedResourceParams {
        target,
        resource_kind,
        resource_name,
        kube_context,
        external_name_discovery_bin: discovery_bin,
    } = p;
    let kube_context = kube_context.as_deref();
    let discovery_bin = discovery_bin.as_deref();

    let kube_ctx = match kube_context {
        Some(context) => context,
        None => sctx.lab.kube_context(target)?,
    };
    crate::crossplane::reconcile_managed_resource(
        kube_ctx,
        resource_kind,
        resource_name,
        discovery_bin,
    )
}

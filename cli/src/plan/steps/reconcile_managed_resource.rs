use anyhow::Result;

use crate::plan::StepContext;

pub fn run(
    sctx: &StepContext<'_>,
    target: &str,
    resource_kind: &str,
    resource_name: &str,
    kube_context: Option<&str>,
    discovery_bin: Option<&str>,
) -> Result<()> {
    let kube_ctx = match kube_context {
        Some(context) => context,
        None => sctx.lab.kube_context(target)?,
    };
    crate::crossplane::reconcile_managed_resource(
        sctx.ctx,
        kube_ctx,
        resource_kind,
        resource_name,
        discovery_bin,
    )
}

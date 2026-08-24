use std::path::PathBuf;

use anyhow::Result;

use crate::domain::plan::BootstrapArgocdKubectlSsaParams;
use crate::io;
use crate::plan::StepContext;

pub fn run(sctx: &StepContext<'_>, p: &BootstrapArgocdKubectlSsaParams) -> Result<()> {
    let BootstrapArgocdKubectlSsaParams {
        target,
        manifest_root,
        kube_context,
        field_manager,
        namespace,
        wait_timeout_seconds,
    } = p;
    let kube_context = kube_context.as_deref();
    let field_manager = field_manager.as_deref();
    let _namespace = namespace.as_deref();

    let kube_context = kube_context.ok_or_else(|| {
        crate::plan::steps::missing_kube_context("bootstrap-argocd-kubectl-ssa", target)
    })?;
    let field_manager = field_manager.unwrap_or("catallaxy-bootstrap");
    let root = PathBuf::from(format!("{}/{manifest_root}", sctx.lab_package));

    io::ssa::apply_manifest_root(
        sctx.ctx,
        io::ssa::ApplyManifests {
            kube_context,
            manifest_root: &root,
            field_manager,
            wait_timeout_seconds: wait_timeout_seconds.unwrap_or(600),
            dry_run: sctx.dry_run,
            cluster: sctx.lab.cluster(target).ok(),
            lab_name: sctx.lab_name,
            secrets_spec: &sctx.lab.secrets,
            secrets_cache: sctx.secrets_cache.as_ref(),
        },
    )
}

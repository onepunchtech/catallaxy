use std::path::PathBuf;

use anyhow::Result;

use crate::io;
use crate::plan::StepContext;

pub fn run(
    sctx: &StepContext<'_>,
    target: &str,
    kube_context: Option<&str>,
    manifest_root: &str,
    field_manager: Option<&str>,
    _namespace: Option<&str>,
    wait_timeout_seconds: Option<u64>,
) -> Result<()> {
    let kube_context = kube_context.ok_or_else(|| {
        anyhow::anyhow!(
            "bootstrap-argocd-kubectl-ssa: missing kubeContext for target '{target}'. \
             The planner must populate `kubeContext` (see `runtimeCtxOf` in \
             `lib/eval/deployment-plan.nix`). No safe default exists."
        )
    })?;
    let field_manager = field_manager.unwrap_or("catallaxy-bootstrap");
    let root = PathBuf::from(format!("{}/{manifest_root}", sctx.lab_package));

    let cluster_config = crate::io::nix::get_cluster_config_with_secrets(sctx.lab, target).ok();

    io::ssa::apply_manifest_root(
        sctx.ctx,
        kube_context,
        &root,
        field_manager,
        wait_timeout_seconds.unwrap_or(600),
        sctx.dry_run,
        cluster_config.as_ref(),
        sctx.secrets_cache.as_ref(),
    )
}

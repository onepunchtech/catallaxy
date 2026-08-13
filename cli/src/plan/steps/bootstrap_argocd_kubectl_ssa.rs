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

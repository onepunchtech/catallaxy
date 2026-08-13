use anyhow::{Result, bail};

use crate::plan::StepContext;

pub async fn run(sctx: &StepContext<'_>) -> Result<()> {
    let repo = sctx.lab.cd.git["repo"].as_str().unwrap_or("");
    if repo.is_empty() {
        bail!(
            "publish-manifests step requires lab.cd.git.repo to be set. \
             Configure it in your lab (see modules/lab/types.nix cd.git)."
        );
    }
    crate::publish::publish(sctx.ctx, sctx.lab_name, false, None, sctx.dry_run).await
}

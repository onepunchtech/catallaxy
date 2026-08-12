use anyhow::{Result, bail};

use crate::plan::StepContext;

pub async fn run(sctx: &StepContext<'_>) -> Result<()> {
    let repo = sctx
        .lab
        .pointer("/cd/git/repo")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if repo.is_empty() {
        bail!(
            "publish-manifests step requires lab.cd.git.repo to be set. \
             Configure it in your lab (see modules/lab/types.nix cd.git)."
        );
    }
    crate::commands::lab::publish::publish(sctx.ctx, sctx.lab_name, false, None, sctx.dry_run).await
}

use anyhow::{Result, bail};
use console::style;

use crate::commands::lab::{pki, state};
use crate::plan::StepContext;

pub async fn run(sctx: &StepContext<'_>) -> Result<()> {
    if sctx.dry_run {
        println!(
            "{} [dry-run] would install lab CA into host trust for '{}'",
            style(">>>").yellow(),
            sctx.lab_name,
        );
        return Ok(());
    }
    let ca_path = state::service_state_dir(sctx.lab_name, "proxy").join("ca.crt");
    if !ca_path.exists() {
        bail!(
            "No lab CA at {}.\n    \
             Expected either a `cert-generate` step (labs with a proxy service) \
             or a `kind = \"ca\"` managed secret whose `hostPaths` project it \
             there. If this lab declares one, run `cata secrets generate` to \
             mint and store it.",
            ca_path.display(),
        );
    }
    pki::ensure_host_trust(sctx.lab_name, &ca_path)?;
    Ok(())
}

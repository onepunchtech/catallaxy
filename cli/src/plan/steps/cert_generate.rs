use anyhow::Result;
use console::style;

use crate::host::pki;
use crate::plan::StepContext;

pub async fn run(sctx: &StepContext<'_>, zone: &str) -> Result<()> {
    if sctx.dry_run {
        println!(
            "{} [dry-run] would ensure ingress cert for '{}' (zone: {})",
            style(">>>").yellow(),
            sctx.lab_name,
            zone,
        );
        return Ok(());
    }
    pki::ensure_ingress_cert(sctx.lab_name, zone)?;
    Ok(())
}

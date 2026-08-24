use anyhow::Result;
use console::style;

use crate::domain::plan::CertGenerateParams;
use crate::host::pki;
use crate::plan::StepContext;

pub fn run(sctx: &StepContext<'_>, p: &CertGenerateParams) -> Result<()> {
    let CertGenerateParams { zone } = p;

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

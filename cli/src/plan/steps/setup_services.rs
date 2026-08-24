use anyhow::Result;

use crate::host::services;
use crate::plan::StepContext;

pub fn run(sctx: &StepContext<'_>) -> Result<()> {
    let provenance =
        crate::domain::provenance::Provenance::new(sctx.lab_name, sctx.ctx.flake_uri());
    for (svc_name, svc) in &sctx.lab.services {
        services::start_service(sctx.lab_name, svc_name, svc, &provenance)?;
    }
    Ok(())
}

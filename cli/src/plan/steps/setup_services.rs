use anyhow::Result;

use crate::commands::lab::services;
use crate::plan::StepContext;

pub async fn run(sctx: &StepContext<'_>) -> Result<()> {
    for (svc_name, svc) in &sctx.lab.services {
        services::start_service(sctx.ctx, sctx.lab_name, svc_name, svc)?;
    }
    Ok(())
}

use anyhow::Result;

use crate::host::services;
use crate::plan::StepContext;

pub async fn run(sctx: &StepContext<'_>) -> Result<()> {
    for (svc_name, svc) in &sctx.lab.services {
        services::start_service(sctx.lab_name, svc_name, svc)?;
    }
    Ok(())
}

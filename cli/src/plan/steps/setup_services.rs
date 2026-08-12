use anyhow::Result;

use crate::commands::lab::services;
use crate::plan::StepContext;

pub async fn run(sctx: &StepContext<'_>) -> Result<()> {
    let Some(map) = sctx
        .lab
        .get("services")
        .and_then(serde_json::Value::as_object)
    else {
        return Ok(());
    };
    for (svc_name, svc) in map {
        services::start_service(sctx.ctx, sctx.lab_name, svc_name, svc)?;
    }
    Ok(())
}

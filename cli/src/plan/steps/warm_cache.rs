use anyhow::Result;
use console::style;

use crate::plan::StepContext;

pub async fn run(ctx: &StepContext<'_>) -> Result<()> {
    let Some(port) = ctx.lab.pointer("/registryPort").and_then(|v| v.as_u64()) else {
        println!(
            "{} Lab registry not enabled; nothing to warm",
            style(">>>").yellow()
        );
        return Ok(());
    };
    let target = format!("localhost:{port}");
    crate::commands::images::warm_to_target_with(
        ctx.ctx,
        Some(ctx.lab_name),
        &target,
        Some(ctx.lab),
        Some(ctx.lab_package),
    )
    .await
}

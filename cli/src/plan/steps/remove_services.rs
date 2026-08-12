use anyhow::Result;
use console::style;

use crate::io;
use crate::plan::StepContext;

pub fn run(sctx: &StepContext<'_>) -> Result<()> {
    let Some(services) = sctx.lab["services"].as_object() else {
        return Ok(());
    };
    for (svc_name, svc) in services {
        let container = svc["container"].as_str().unwrap_or("");
        let svc_desc = svc["description"].as_str().unwrap_or(svc_name);
        if container.is_empty() {
            continue;
        }
        println!("{} Removing {}...", style(">>>").cyan(), svc_desc);
        io::docker::stop_container(sctx.ctx, container)?;
        println!("{} {} removed", style(">>>").green(), svc_desc);
    }
    Ok(())
}

use anyhow::Result;
use console::style;

use crate::io;
use crate::plan::StepContext;

pub fn run(sctx: &StepContext<'_>) -> Result<()> {
    let services = &sctx.lab.services;
    for svc in services.values() {
        let container = svc.container.as_str();
        let svc_desc = svc.description.as_str();
        if container.is_empty() {
            continue;
        }
        println!("{} Removing {}...", style(">>>").cyan(), svc_desc);
        io::docker::stop_container(container)?;
        println!("{} {} removed", style(">>>").green(), svc_desc);
    }
    Ok(())
}

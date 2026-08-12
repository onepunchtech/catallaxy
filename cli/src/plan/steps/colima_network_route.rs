use anyhow::Result;
use console::style;

use crate::commands::lab::dns;
use crate::plan::StepContext;

pub async fn run(sctx: &StepContext<'_>, subnet: &str, profile: &str) -> Result<()> {
    if !cfg!(target_os = "macos") {
        return Ok(());
    }

    if sctx.dry_run {
        println!(
            "{} [dry-run] would route {} through Colima VM (profile: {})",
            style(">>>").yellow(),
            subnet,
            profile,
        );
        return Ok(());
    }

    let Some(vm_ip) = dns::get_colima_vm_ip() else {
        return Ok(());
    };
    dns::setup_host_networking_macos(subnet, &vm_ip, profile)
}

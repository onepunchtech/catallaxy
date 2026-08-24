use anyhow::Result;
use console::style;

use crate::domain::plan::DnsSetupParams;
use crate::host::dns;
use crate::plan::StepContext;

pub fn run(sctx: &StepContext<'_>, p: &DnsSetupParams) -> Result<()> {
    let DnsSetupParams { host, port, zone } = p;

    if sctx.dry_run {
        println!(
            "{} [dry-run] would point host DNS for '{}' at {}:{}",
            style(">>>").yellow(),
            zone,
            host,
            port,
        );
        return Ok(());
    }
    dns::dns_setup(host, *port, zone)
}

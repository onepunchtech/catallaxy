use anyhow::Result;
use console::style;

use crate::domain::plan::DnsTeardownParams;
use crate::host::dns;
use crate::plan::StepContext;

pub async fn run(sctx: &StepContext<'_>, p: &DnsTeardownParams) -> Result<()> {
    let DnsTeardownParams { zone } = p;

    if sctx.dry_run {
        println!(
            "{} [dry-run] would stop pointing host DNS for '{}' at this lab",
            style(">>>").yellow(),
            zone,
        );
        return Ok(());
    }
    dns::dns_teardown(zone).await
}

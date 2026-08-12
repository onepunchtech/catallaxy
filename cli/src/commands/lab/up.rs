use anyhow::Result;

use crate::config::Context as CataContext;
use crate::plan::{Direction, execute};

pub async fn run(
    ctx: &CataContext,
    name: &str,
    dry_run: bool,
    up_to: Option<String>,
) -> Result<()> {
    execute(ctx, name, dry_run, Direction::Deploy, up_to.as_deref()).await
}

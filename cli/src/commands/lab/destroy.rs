use anyhow::Result;

use crate::config::Context as CataContext;
use crate::plan::{Direction, execute};

pub async fn run(ctx: &CataContext, name: &str) -> Result<()> {
    execute(ctx, name, false, Direction::Teardown, None).await
}

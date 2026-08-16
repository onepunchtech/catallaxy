use anyhow::{Context, Result};
use console::style;

use crate::config::Context as CataContext;

pub async fn ops(ctx: &CataContext, name: &str, args: &[String]) -> Result<()> {
    let lab = crate::io::nix::get_lab_spec(ctx, name)?;

    let Some(ops_tool_path) = lab.ops_tool_path.as_deref() else {
        println!(
            "{} No ops commands defined for lab '{name}'.",
            style(">>>").yellow()
        );
        println!("  Define commands in lab.ops.commands in your lab config.");
        return Ok(());
    };

    crate::io::nix::build_lab_package(ctx, name)?;

    let status = crate::io::process::run_tool(ops_tool_path, args)
        .with_context(|| format!("Failed to run ops tool: {ops_tool_path}"))?;

    if !status.success() {
        std::process::exit(status.code().unwrap_or(1));
    }
    Ok(())
}

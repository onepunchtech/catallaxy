use std::process::Command;

use anyhow::{Context, Result};
use console::style;

use crate::config::Context as CataContext;

pub async fn ops(ctx: &CataContext, name: &str, args: &[String]) -> Result<()> {
    let lab_package = crate::io::nix::build_lab_package(ctx, name)?;
    let ops_bin = format!("{lab_package}/bin/{name}-ops");

    if std::path::Path::new(&ops_bin).exists() {
        let mut cmd = Command::new(&ops_bin);
        crate::io::trust::apply(&mut cmd);
        let status = cmd
            .args(args)
            .status()
            .with_context(|| format!("Failed to run ops tool: {}", ops_bin))?;

        if !status.success() {
            std::process::exit(status.code().unwrap_or(1));
        }
        Ok(())
    } else {
        println!(
            "{} No ops commands defined for lab '{name}'.",
            style(">>>").yellow()
        );
        println!("  Define commands in lab.ops.commands in your lab config.");
        Ok(())
    }
}

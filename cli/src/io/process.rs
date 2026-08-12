use std::process::{Command, Stdio};

use anyhow::{Context, Result, bail};
use console::style;

use crate::config::Context as CataContext;
use crate::error::{CataError, CataResult};

pub fn check_tool(name: &str) -> CataResult<()> {
    which::which(name).map_err(|_| CataError::ToolMissing {
        name: name.to_string(),
    })?;
    Ok(())
}

pub fn check_required_tools() -> CataResult<()> {
    let tools = ["kubectl", "helm", "nix"];
    for tool in tools {
        check_tool(tool)?;
    }
    if cfg!(target_os = "macos") {
        check_tool("colima")?;
    }
    Ok(())
}

pub fn check_all_tools() -> Vec<(String, bool, String)> {
    let tools = ["nix", "kubectl", "helm", "kapp", "sops", "k3d", "crane"];

    tools
        .iter()
        .map(|&name| match which::which(name) {
            Ok(path) => (name.to_string(), true, path.display().to_string()),
            Err(_) => (name.to_string(), false, "not found".to_string()),
        })
        .collect()
}

pub fn run_streaming(cmd: &mut Command, ctx: &CataContext) -> Result<()> {
    super::trust::apply(cmd);
    if ctx.verbose {
        eprintln!("{} {:?}", style("Running:").dim(), cmd);
    }

    let status = cmd
        .stdin(Stdio::null())
        .status()
        .context("Failed to execute command")?;

    if !status.success() {
        bail!("Command failed with status: {status}");
    }

    Ok(())
}

pub fn run_capture(cmd: &mut Command, ctx: &CataContext) -> Result<String> {
    super::trust::apply(cmd);
    if ctx.verbose {
        eprintln!("{} {:?}", style("Running:").dim(), cmd);
    }

    let output = cmd
        .stdin(Stdio::null())
        .output()
        .context("Failed to execute command")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!("Command failed: {stderr}");
    }

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

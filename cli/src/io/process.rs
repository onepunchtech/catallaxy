use std::process::{Command, ExitStatus, Output, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::{Context, Result, bail};
use console::style;

use crate::error::{CataError, CataResult};

static VERBOSE: AtomicBool = AtomicBool::new(false);

pub fn set_verbose(verbose: bool) {
    VERBOSE.store(verbose, Ordering::Relaxed);
}

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

pub fn prepare_env(cmd: &mut Command) {
    super::trust::apply(cmd);
}

fn prepare(cmd: &mut Command) {
    super::trust::apply(cmd);
    if VERBOSE.load(Ordering::Relaxed) {
        eprintln!("{} {:?}", style("Running:").dim(), cmd);
    }
}

pub fn run_streaming(cmd: &mut Command) -> Result<()> {
    prepare(cmd);

    let status = cmd
        .stdin(Stdio::null())
        .status()
        .context("Failed to execute command")?;

    if !status.success() {
        bail!("Command failed with status: {status}");
    }

    Ok(())
}

pub fn run_interactive(cmd: &mut Command) -> Result<()> {
    prepare(cmd);

    let status = cmd.status().context("Failed to execute command")?;

    if !status.success() {
        bail!("Command failed with status: {status}");
    }

    Ok(())
}

pub fn run_capture(cmd: &mut Command) -> Result<String> {
    let output = run_output(cmd)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!("Command failed: {stderr}");
    }

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

pub fn run_output(cmd: &mut Command) -> Result<Output> {
    prepare(cmd);

    cmd.stdin(Stdio::null())
        .output()
        .context("Failed to execute command")
}

pub fn run_status(cmd: &mut Command) -> Result<ExitStatus> {
    prepare(cmd);

    cmd.status().context("Failed to execute command")
}

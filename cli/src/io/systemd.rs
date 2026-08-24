use std::process::Command;

use anyhow::{Context, Result};

use crate::io::process::{run_capture, run_interactive};

pub fn is_active(unit: &str) -> bool {
    let mut cmd = Command::new("systemctl");
    cmd.args(["is-active", unit]);
    run_capture(&mut cmd)
        .map(|o| o.trim() == "active")
        .unwrap_or(false)
}

/// # Errors
///
/// If `sudo` cannot be spawned, or exits non-zero because the operator
/// declined the prompt or the unit failed to start.
pub fn restart(unit: &str) -> Result<()> {
    let mut cmd = Command::new("sudo");
    cmd.args(["systemctl", "restart", unit]);
    run_interactive(&mut cmd).with_context(|| format!("restarting {unit}"))
}

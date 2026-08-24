use std::path::Path;
use std::process::Command;

use anyhow::{Context, Result};

use crate::io::process::run_interactive;

/// # Errors
///
/// If `sudo` cannot be spawned, or exits non-zero because the operator
/// declined the prompt or `mkdir` failed. sudo keeps this process's stdin, so
/// a password prompt reaches the terminal.
pub fn make_directory(path: &str) -> Result<()> {
    let mut cmd = Command::new("sudo");
    cmd.args(["mkdir", "-p", path]);
    run_interactive(&mut cmd).with_context(|| format!("creating {path}"))
}

/// # Errors
///
/// If `sudo` cannot be spawned, or exits non-zero because the operator
/// declined the prompt or the source is unreadable.
pub fn install_file(source: &Path, destination: &str) -> Result<()> {
    let mut cmd = Command::new("sudo");
    cmd.args(["install", "-m", "0644"])
        .arg(source)
        .arg(destination);
    run_interactive(&mut cmd).with_context(|| format!("installing {destination}"))
}

/// # Errors
///
/// If `sudo` cannot be spawned, or exits non-zero because the operator
/// declined the prompt. `rm -f`, so a path that is not there is success.
pub fn remove_file(path: &str) -> Result<()> {
    let mut cmd = Command::new("sudo");
    cmd.args(["rm", "-f", path]);
    run_interactive(&mut cmd).with_context(|| format!("removing {path}"))
}

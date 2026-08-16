use std::path::Path;
use std::process::Command;

use anyhow::{Context, Result};

use crate::io::process::run_interactive;

pub fn make_directory(path: &str) -> Result<()> {
    let mut cmd = Command::new("sudo");
    cmd.args(["mkdir", "-p", path]);
    run_interactive(&mut cmd).with_context(|| format!("creating {path}"))
}

pub fn install_file(source: &Path, destination: &str) -> Result<()> {
    let mut cmd = Command::new("sudo");
    cmd.args(["install", "-m", "0644"])
        .arg(source)
        .arg(destination);
    run_interactive(&mut cmd).with_context(|| format!("installing {destination}"))
}

pub fn remove_file(path: &str) -> Result<()> {
    let mut cmd = Command::new("sudo");
    cmd.args(["rm", "-f", path]);
    run_interactive(&mut cmd).with_context(|| format!("removing {path}"))
}

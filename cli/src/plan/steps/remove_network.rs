use std::process::{Command, Stdio};

use anyhow::Result;
use console::style;

use crate::plan::StepContext;

pub async fn run(sctx: &StepContext<'_>) -> Result<()> {
    let docker_subnet = sctx
        .lab
        .pointer("/network/dockerSubnet")
        .and_then(|v| v.as_str())
        .unwrap_or("172.19.0.0/16");

    if cfg!(target_os = "macos") {
        let _ = crate::commands::lab::dns::teardown_host_networking_macos(docker_subnet);
    }

    let network_name = sctx
        .lab
        .pointer("/network/name")
        .and_then(|v| v.as_str())
        .unwrap_or(sctx.lab_name);
    println!(
        "{} Removing Docker network '{}'...",
        style(">>>").cyan(),
        network_name,
    );
    let _ = Command::new("docker")
        .args(["network", "rm", network_name])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    Ok(())
}

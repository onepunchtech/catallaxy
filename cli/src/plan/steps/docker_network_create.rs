use std::process::{Command, Stdio};

use anyhow::{Context, Result, bail};
use console::style;

use crate::domain::plan::DockerNetworkCreateParams;
use crate::plan::StepContext;

pub async fn run(sctx: &StepContext<'_>, p: &DockerNetworkCreateParams) -> Result<()> {
    let DockerNetworkCreateParams {
        name,
        subnet,
        gateway,
    } = p;

    if sctx.dry_run {
        println!(
            "{} [dry-run] would ensure docker network '{}' (subnet: {}, gateway: {})",
            style(">>>").yellow(),
            name,
            subnet,
            gateway,
        );
        return Ok(());
    }

    println!(
        "{} Ensuring '{}' network exists (subnet: {})...",
        style(">>>").cyan(),
        name,
        subnet
    );

    let already = Command::new("docker")
        .args(["network", "inspect", name])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false);

    if already {
        return Ok(());
    }

    let output = Command::new("docker")
        .args([
            "network",
            "create",
            "-d",
            "bridge",
            "--subnet",
            subnet,
            "--gateway",
            gateway,
            name,
        ])
        .output()
        .context("failed to invoke `docker network create`")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!(
            "Failed to create docker network '{}' (subnet {}):\n{}\n\n\
             Common causes:\n  \
             - subnet overlap with an existing docker network — pick a distinct \
             `lab.network.dockerSubnet` in your env module (e.g. \"172.30.0.0/16\")\n  \
             - docker daemon not reachable / user not in the `docker` group",
            name,
            subnet,
            stderr.trim(),
        );
    }

    Ok(())
}

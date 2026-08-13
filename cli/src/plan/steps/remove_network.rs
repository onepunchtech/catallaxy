use std::process::{Command, Stdio};

use anyhow::Result;
use console::style;

use crate::plan::StepContext;

pub async fn run(sctx: &StepContext<'_>) -> Result<()> {
    let docker_subnet = sctx.lab.network.docker_subnet.as_str();

    if cfg!(target_os = "macos") {
        let _ = crate::commands::lab::dns::teardown_host_networking_macos(docker_subnet);
    }

    let network_name = sctx.lab.network.name.as_str();
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

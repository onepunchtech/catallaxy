use anyhow::Result;
use console::style;

use crate::io;
use crate::plan::StepContext;

pub async fn run(sctx: &StepContext<'_>) -> Result<()> {
    let docker_subnet = sctx.lab.network.docker_subnet.as_str();

    if cfg!(target_os = "macos") {
        let _ = crate::host::network::teardown_host_networking_macos(docker_subnet);
    }

    let network_name = sctx.lab.network.name.as_str();
    println!(
        "{} Removing Docker network '{}'...",
        style(">>>").cyan(),
        network_name,
    );
    io::docker::remove_network(network_name);
    Ok(())
}

use std::collections::HashMap;
use std::process::{Command, Stdio};

use anyhow::Result;

use crate::config::Context as CataContext;
use crate::io::process::run_streaming;

pub fn container_running(name: &str) -> bool {
    let output = Command::new("docker")
        .args(["inspect", "-f", "{{.State.Running}}", name])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output();

    match output {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim() == "true",
        _ => false,
    }
}

pub fn container_exists(name: &str) -> bool {
    Command::new("docker")
        .args(["inspect", name])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_or(false, |s| s.success())
}

pub fn run_container(
    ctx: &CataContext,
    name: &str,
    image: &str,
    ports: &[&str],
    volume_mounts: &[(&str, &str)],
    command: &[&str],
) -> Result<()> {
    if container_exists(name) && !container_running(name) {
        let _ = Command::new("docker")
            .args(["rm", name])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }

    let mut cmd = Command::new("docker");
    cmd.args(["run", "-d", "--name", name, "--restart", "unless-stopped"]);

    for port in ports {
        cmd.args(["-p", port]);
    }

    for (host_path, container_path) in volume_mounts {
        cmd.args(["-v", &format!("{host_path}:{container_path}")]);
    }

    cmd.arg(image);
    cmd.args(command);
    run_streaming(&mut cmd, ctx)
}

pub fn get_container_ip(container: &str) -> Option<String> {
    let output = Command::new("docker")
        .args(["inspect", "-f", "{{.NetworkSettings.IPAddress}}", container])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok()?;

    if output.status.success() {
        let ip = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !ip.is_empty() {
            return Some(ip);
        }
    }
    None
}

#[allow(clippy::too_many_arguments)]
pub fn run_container_extended(
    ctx: &CataContext,
    name: &str,
    image: &str,
    ports: &[&str],
    volume_mounts: &[(&str, &str)],
    link: Option<&str>,
    networks: &[&str],
    dns_ips: &[String],
    command: &[&str],
    network_mode: Option<&str>,
    cap_add: &[&str],
    network_ips: &HashMap<String, String>,
) -> Result<()> {
    if container_exists(name) && !container_running(name) {
        let _ = Command::new("docker")
            .args(["rm", name])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }

    let mut cmd = Command::new("docker");
    cmd.args(["run", "-d", "--name", name, "--restart", "unless-stopped"]);

    if let Some(mode) = network_mode {
        cmd.args(["--network", mode]);
    } else if let Some(first_net) = networks.first() {
        cmd.args(["--network", first_net]);
    }

    for cap in cap_add {
        cmd.args(["--cap-add", cap]);
    }

    for port in ports {
        cmd.args(["-p", port]);
    }

    for (host_path, container_path) in volume_mounts {
        cmd.args(["-v", &format!("{host_path}:{container_path}")]);
    }

    for dns_ip in dns_ips {
        cmd.args(["--dns", dns_ip]);
    }

    if let Some(link_container) = link {
        cmd.args(["--link", link_container]);
    }

    cmd.arg(image);
    cmd.args(command);
    run_streaming(&mut cmd, ctx)?;

    for network in networks {
        if let Some(ip) = network_ips.get(*network) {
            let _ = Command::new("docker")
                .args(["network", "connect", "--ip", ip, network, name])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
        } else {
            let _ = Command::new("docker")
                .args(["network", "connect", network, name])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
        }
    }

    Ok(())
}

pub fn stop_container(ctx: &CataContext, name: &str) -> Result<()> {
    if container_running(name) {
        let mut cmd = Command::new("docker");
        cmd.args(["stop", name]);
        run_streaming(&mut cmd, ctx)?;
    }

    if container_exists(name) {
        let mut cmd = Command::new("docker");
        cmd.args(["rm", name]);
        run_streaming(&mut cmd, ctx)?;
    }

    Ok(())
}

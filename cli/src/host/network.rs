use std::process::{Command, Stdio};

use anyhow::{Context, Result, bail};
use console::style;

use crate::io;

pub fn setup_host_networking_macos(
    docker_subnet: &str,
    vm_ip: &str,
    colima_profile: &str,
) -> Result<()> {
    println!(
        "{} Configuring host networking (macOS + Colima)",
        style(">>>").cyan()
    );

    println!(
        "{} Enabling IP forwarding in Colima VM...",
        style(">>>").cyan()
    );
    open_vm_forwarding(docker_subnet, colima_profile);
    add_host_route(docker_subnet, vm_ip)
}

fn open_vm_forwarding(docker_subnet: &str, colima_profile: &str) {
    let _ = io::colima::ssh_exec(
        colima_profile,
        &["sudo", "sysctl", "-w", "net.ipv4.ip_forward=1"],
    );

    let _ = io::colima::ssh_exec(
        colima_profile,
        &["sudo", "iptables", "-P", "FORWARD", "ACCEPT"],
    );

    let check_raw = Command::new("colima")
        .args([
            "ssh",
            "--profile",
            colima_profile,
            "--",
            "sudo",
            "iptables",
            "-t",
            "raw",
            "-C",
            "PREROUTING",
            "-d",
            docker_subnet,
            "-i",
            "col0",
            "-j",
            "ACCEPT",
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();

    if !matches!(check_raw, Ok(s) if s.success()) {
        let _ = io::colima::ssh_exec(
            colima_profile,
            &[
                "sudo",
                "iptables",
                "-t",
                "raw",
                "-I",
                "PREROUTING",
                "-d",
                docker_subnet,
                "-i",
                "col0",
                "-j",
                "ACCEPT",
            ],
        );
    }

    let check_filter = Command::new("colima")
        .args([
            "ssh",
            "--profile",
            colima_profile,
            "--",
            "sudo",
            "iptables",
            "-C",
            "DOCKER-USER",
            "-d",
            docker_subnet,
            "-i",
            "col0",
            "-j",
            "ACCEPT",
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();

    if !matches!(check_filter, Ok(s) if s.success()) {
        let _ = io::colima::ssh_exec(
            colima_profile,
            &[
                "sudo",
                "iptables",
                "-I",
                "DOCKER-USER",
                "-d",
                docker_subnet,
                "-i",
                "col0",
                "-j",
                "ACCEPT",
            ],
        );
    }
}

fn add_host_route(docker_subnet: &str, vm_ip: &str) -> Result<()> {
    let existing_gw = Command::new("route")
        .args([
            "-n",
            "get",
            docker_subnet.split('/').next().unwrap_or("172.19.0.0"),
        ])
        .output()
        .ok()
        .and_then(|o| {
            let stdout = String::from_utf8_lossy(&o.stdout).to_string();
            stdout
                .lines()
                .find(|l| l.trim().starts_with("gateway:"))
                .map(|l| l.trim().trim_start_matches("gateway:").trim().to_string())
        });

    match existing_gw.as_deref() {
        Some(gw) if gw == vm_ip => {
            println!(
                "{} Route already configured: {} via {}",
                style(">>>").green(),
                docker_subnet,
                vm_ip
            );
        }
        Some(old_gw) => {
            println!(
                "{} Updating route: {} via {} (was {})",
                style(">>>").cyan(),
                docker_subnet,
                vm_ip,
                old_gw
            );
            println!(
                "    This requires sudo to update a network route so your Mac\n    \
                 can reach Docker containers directly."
            );
            let _ = Command::new("sudo")
                .args(["route", "-n", "delete", "-net", docker_subnet])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
            let status = Command::new("sudo")
                .args(["route", "-n", "add", "-net", docker_subnet, vm_ip])
                .status()
                .context("Failed to run sudo route add")?;
            if !status.success() {
                bail!("Failed to add route for {docker_subnet} via {vm_ip}");
            }
        }
        None => {
            println!(
                "{} Adding route: {} via {}",
                style(">>>").cyan(),
                docker_subnet,
                vm_ip
            );
            println!(
                "    This requires sudo to add a network route so your Mac\n    \
                 can reach Docker containers directly."
            );
            let status = Command::new("sudo")
                .args(["route", "-n", "add", "-net", docker_subnet, vm_ip])
                .status()
                .context("Failed to run sudo route add")?;
            if !status.success() {
                bail!("Failed to add route for {docker_subnet} via {vm_ip}");
            }
        }
    }

    println!("{} Host networking configured", style(">>>").green());
    Ok(())
}

pub fn teardown_host_networking_macos(docker_subnet: &str) -> Result<()> {
    println!("{} Removing route: {}", style(">>>").cyan(), docker_subnet);

    let status = Command::new("sudo")
        .args(["route", "-n", "delete", "-net", docker_subnet])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();

    match status {
        Ok(s) if s.success() => {
            println!("{} Route removed", style(">>>").green());
        }
        _ => {
            println!(
                "{} No route to remove (already clean)",
                style(">>>").yellow()
            );
        }
    }

    Ok(())
}

pub fn get_colima_vm_ip() -> Option<String> {
    let output = Command::new("colima")
        .args(["list", "-j"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok();

    if let Some(ref out) = output
        && out.status.success()
    {
        let json_str = String::from_utf8_lossy(&out.stdout);
        for line in json_str.lines() {
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(line)
                && let Some(addr) = parsed["address"].as_str()
                && !addr.is_empty()
            {
                return Some(addr.to_string());
            }
        }
    }

    if cfg!(target_os = "macos")
        && let Ok(arp_out) = Command::new("arp")
            .args(["-an"])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .output()
    {
        let arp_str = String::from_utf8_lossy(&arp_out.stdout);
        for line in arp_str.lines() {
            if line.contains("bridge100")
                && let Some(start) = line.find('(')
                && let Some(end) = line.find(')')
            {
                let ip = &line[start + 1..end];
                if !ip.is_empty() {
                    return Some(ip.to_string());
                }
            }
        }
    }

    None
}

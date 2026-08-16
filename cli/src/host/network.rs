use anyhow::Result;
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
    let unopened = open_vm_forwarding(docker_subnet, colima_profile);
    if !unopened.is_empty() {
        println!(
            "{} the Colima VM did not accept {} of its forwarding settings:",
            style("Warning:").yellow(),
            unopened.len(),
        );
        for what in &unopened {
            println!("{}   {what}", style(">>>").yellow());
        }
        println!(
            "{} the lab will come up, but traffic from this machine to \
             containers may not reach them. `colima ssh --profile {colima_profile}` \
             to look.",
            style(">>>").yellow(),
        );
    }

    add_host_route(docker_subnet, vm_ip)
}

/// Runs a setting the VM needs and names it if it did not take. These used to
/// be `let _ =`, in a function returning `()`, so a lab could come up fully
/// and simply not carry traffic.
fn apply(profile: &str, what: &str, args: &[&str]) -> Option<String> {
    match io::colima::ssh_exec(profile, args) {
        Ok(s) if s.success() => None,
        Ok(s) => Some(format!("{what} (exit {})", s.code().unwrap_or(-1))),
        Err(e) => Some(format!("{what} ({e})")),
    }
}

fn open_vm_forwarding(docker_subnet: &str, colima_profile: &str) -> Vec<String> {
    let mut failed = Vec::new();

    failed.extend(apply(
        colima_profile,
        "enable IPv4 forwarding",
        &["sudo", "sysctl", "-w", "net.ipv4.ip_forward=1"],
    ));

    failed.extend(apply(
        colima_profile,
        "set the FORWARD policy to ACCEPT",
        &["sudo", "iptables", "-P", "FORWARD", "ACCEPT"],
    ));

    let check_raw = io::colima::ssh_exec(
        colima_profile,
        &[
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
        ],
    );

    // The -C above is a probe: it fails when the rule is absent, which is the
    // normal case and why we are here. The insert is not a probe.
    if !matches!(check_raw, Ok(s) if s.success()) {
        failed.extend(apply(
            colima_profile,
            "accept traffic to the lab subnet in the raw table",
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
        ));
    }

    let check_filter = io::colima::ssh_exec(
        colima_profile,
        &[
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
        ],
    );

    if !matches!(check_filter, Ok(s) if s.success()) {
        failed.extend(apply(
            colima_profile,
            "accept traffic to the lab subnet in DOCKER-USER",
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
        ));
    }

    failed
}

fn add_host_route(docker_subnet: &str, vm_ip: &str) -> Result<()> {
    let existing_gw =
        io::route::gateway_for(docker_subnet.split('/').next().unwrap_or("172.19.0.0"));

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
            let _ = io::route::delete(docker_subnet);
            io::route::add(docker_subnet, vm_ip)?;
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
            io::route::add(docker_subnet, vm_ip)?;
        }
    }

    println!("{} Host networking configured", style(">>>").green());
    Ok(())
}

pub fn teardown_host_networking_macos(docker_subnet: &str) -> Result<()> {
    println!("{} Removing route: {}", style(">>>").cyan(), docker_subnet);

    match io::route::delete(docker_subnet) {
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
    if let Some(list) = io::colima::list_json()
        && let Some(addr) = io::colima::address_in_list(&list)
    {
        return Some(addr);
    }

    if cfg!(target_os = "macos")
        && let Some(arp) = io::route::arp_table()
        && let Some(ip) = io::route::bridge_address(&arp, "bridge100")
    {
        return Some(ip);
    }

    None
}

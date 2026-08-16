use std::process::{Command, Stdio};

use anyhow::{Context, Result, bail};

pub fn gateway_for(destination: &str) -> Option<String> {
    let out = Command::new("route")
        .args(["-n", "get", destination])
        .output()
        .ok()?;
    parse_gateway(&String::from_utf8_lossy(&out.stdout))
}

pub fn parse_gateway(route_output: &str) -> Option<String> {
    route_output
        .lines()
        .find(|l| l.trim().starts_with("gateway:"))
        .map(|l| l.trim().trim_start_matches("gateway:").trim().to_string())
}

pub fn delete(subnet: &str) -> std::io::Result<std::process::ExitStatus> {
    Command::new("sudo")
        .args(["route", "-n", "delete", "-net", subnet])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
}

pub fn add(subnet: &str, gateway: &str) -> Result<()> {
    let status = Command::new("sudo")
        .args(["route", "-n", "add", "-net", subnet, gateway])
        .status()
        .context("Failed to run sudo route add")?;
    if !status.success() {
        bail!("Failed to add route for {subnet} via {gateway}");
    }
    Ok(())
}

pub fn arp_table() -> Option<String> {
    let out = Command::new("arp")
        .args(["-an"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    Some(String::from_utf8_lossy(&out.stdout).to_string())
}

pub fn bridge_address(arp_output: &str, interface: &str) -> Option<String> {
    arp_output.lines().find_map(|line| {
        if !line.contains(interface) {
            return None;
        }
        let start = line.find('(')?;
        let end = line.find(')')?;
        let ip = &line[start + 1..end];
        (!ip.is_empty()).then(|| ip.to_string())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_gateway_is_read_off_its_own_indented_line() {
        let out = "   route to: 172.19.0.0\ndestination: 172.19.0.0\n   gateway: 192.168.106.2\n";
        assert_eq!(parse_gateway(out), Some("192.168.106.2".to_string()));
    }

    #[test]
    fn a_destination_with_no_route_has_no_gateway() {
        assert_eq!(
            parse_gateway("route: writing to routing socket: not in table"),
            None
        );
    }

    #[test]
    fn the_bridge_address_comes_from_the_arp_entry_naming_that_interface() {
        let arp = "? (192.168.64.1) at 0:0:0:0:0:0 on bridge100 ifscope permanent [ethernet]\n\
                   ? (10.0.0.1) at 1:2:3:4:5:6 on en0 ifscope [ethernet]\n";
        assert_eq!(
            bridge_address(arp, "bridge100"),
            Some("192.168.64.1".to_string())
        );
    }

    #[test]
    fn an_arp_table_without_that_interface_yields_nothing() {
        assert_eq!(
            bridge_address("? (10.0.0.1) at 1:2:3:4:5:6 on en0\n", "bridge100"),
            None
        );
    }
}

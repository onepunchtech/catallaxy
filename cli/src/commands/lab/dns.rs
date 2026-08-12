use std::fs;
use std::io::Write as IoWrite;
use std::process::{Command, Stdio};

use anyhow::{Context, Result, bail};
use console::style;

use crate::config::Context as CataContext;
use crate::io;

const RESOLVED_CONF_DIR: &str = "/etc/systemd/resolved.conf.d";

const SHARED_TEST_CONF: &str = "/etc/systemd/resolved.conf.d/catallaxy-test.conf";

const DEFAULT_DNS_HOST_PORT: u64 = 5354;

struct ResolvedDropIn {
    path: String,
    domains: String,
    shared: bool,
}

fn per_zone_conf(zone: &str) -> String {
    format!("{}/{}.conf", RESOLVED_CONF_DIR, zone.replace('.', "-"))
}

fn resolved_drop_in(host: &str, port: u64, zone: &str) -> ResolvedDropIn {
    if host == "127.0.0.1" && port == DEFAULT_DNS_HOST_PORT && zone.ends_with(".test") {
        ResolvedDropIn {
            path: SHARED_TEST_CONF.to_string(),
            domains: "test".to_string(),
            shared: true,
        }
    } else {
        ResolvedDropIn {
            path: per_zone_conf(zone),
            domains: zone.to_string(),
            shared: false,
        }
    }
}

fn zone_is_shell_safe(zone: &str) -> bool {
    !zone.is_empty()
        && zone
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-' || c == '_')
}

pub async fn dns(ctx: &CataContext, name: &str, setup: bool, teardown: bool) -> Result<()> {
    let lab = crate::io::nix::get_lab_config(ctx, name)?;

    let Some(dns_info) = lab.get("dnsInfo").filter(|v| !v.is_null()) else {
        println!(
            "{} No DNS configured (enable lab.dns to use local DNS resolution)",
            style(">>>").yellow()
        );
        return Ok(());
    };
    let host = dns_info["host"].as_str().unwrap_or("127.0.0.1");
    let port = dns_info["port"].as_u64().unwrap_or(5353);
    let zone = dns_info["zone"].as_str().unwrap_or("lab.test");

    let docker_subnet = lab
        .pointer("/network/dockerSubnet")
        .and_then(|v| v.as_str())
        .unwrap_or("172.19.0.0/16");

    if teardown {
        return dns_teardown(zone, docker_subnet).await;
    }

    if setup {
        return dns_setup(host, port, zone, docker_subnet).await;
    }

    println!("{} Lab DNS Configuration", style("catallaxy").cyan().bold());
    println!();
    println!("DNS Server: {}:{}", host, port);
    println!("Zone: {}", zone);
    println!();
    println!("To resolve *.{} from your terminal:", zone);
    println!();

    println!("{}", style("macOS:").bold());
    println!("  sudo mkdir -p /etc/resolver");
    println!(
        "  echo -e \"nameserver {}\\nport {}\" | sudo tee /etc/resolver/{}",
        host, port, zone
    );
    println!();

    let drop_in = resolved_drop_in(host, port, zone);
    println!("{}", style("Linux (systemd-resolved):").bold());
    println!("  sudo mkdir -p {}", RESOLVED_CONF_DIR);
    println!("  cat <<EOF | sudo tee {}", drop_in.path);
    println!("  [Resolve]");
    println!("  DNS={}:{}", host, port);
    println!("  Domains=~{}", drop_in.domains);
    println!("  EOF");
    println!("  sudo systemctl restart systemd-resolved");
    if drop_in.shared {
        println!("  (one drop-in covers every *.test lab, install it once)");
    }
    println!();

    println!("{}", style("Linux (dnsmasq):").bold());
    println!("  Add to /etc/dnsmasq.conf:");
    println!("  server=/{}/{}#{}", zone, host, port);
    println!();

    println!("{}", style("Test:").bold());
    println!("  dig @{} -p {} git.{}", host, port, zone);
    println!();

    println!("{}", style("Auto-configure:").bold());
    println!("  cata lab dns --setup     # Configure resolver (requires sudo)");
    println!("  cata lab dns --teardown  # Remove configuration");

    Ok(())
}

pub async fn dns_setup(host: &str, port: u64, zone: &str, _docker_subnet: &str) -> Result<()> {
    println!(
        "{} Setting up DNS resolution for *.{}",
        style(">>>").cyan(),
        zone
    );

    if cfg!(target_os = "macos") {
        dns_setup_macos(host, port, zone)
    } else {
        dns_setup_linux(host, port, zone)
    }
}

fn dns_setup_macos(host: &str, port: u64, zone: &str) -> Result<()> {
    let dns_host = get_colima_vm_ip().unwrap_or_else(|| host.to_string());

    let resolver_dir = "/etc/resolver";
    let resolver_file = format!("{}/{}", resolver_dir, zone);

    if std::path::Path::new(&resolver_file).exists() {
        let content = fs::read_to_string(&resolver_file).unwrap_or_default();
        if content.contains(&format!("nameserver {}", dns_host))
            && content.contains(&format!("port {}", port))
        {
            println!(
                "{} DNS resolver already configured at {}",
                style(">>>").green(),
                resolver_file
            );
        } else {
            println!(
                "{} Updating {} (nameserver → {})...",
                style(">>>").cyan(),
                resolver_file,
                dns_host
            );
            let resolver_content = format!("nameserver {}\nport {}\n", dns_host, port);
            let mut tee = Command::new("sudo")
                .args(["tee", &resolver_file])
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .spawn()
                .context("Failed to run sudo tee")?;
            if let Some(stdin) = tee.stdin.as_mut() {
                stdin.write_all(resolver_content.as_bytes())?;
            }
            let tee_status = tee.wait()?;
            if !tee_status.success() {
                bail!("Failed to write {}", resolver_file);
            }
            println!(
                "{} DNS resolver updated at {}",
                style(">>>").green(),
                resolver_file
            );
        }
    } else {
        let resolver_content = format!("nameserver {}\nport {}\n", dns_host, port);

        println!("{} Creating {}...", style(">>>").cyan(), resolver_file);

        let mkdir_status = Command::new("sudo")
            .args(["mkdir", "-p", resolver_dir])
            .status()
            .context("Failed to run sudo mkdir")?;

        if !mkdir_status.success() {
            bail!("Failed to create {}", resolver_dir);
        }

        let mut tee = Command::new("sudo")
            .args(["tee", &resolver_file])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .spawn()
            .context("Failed to run sudo tee")?;

        if let Some(stdin) = tee.stdin.as_mut() {
            stdin.write_all(resolver_content.as_bytes())?;
        }

        let tee_status = tee.wait()?;
        if !tee_status.success() {
            bail!("Failed to write {}", resolver_file);
        }

        println!(
            "{} DNS resolver configured at {}",
            style(">>>").green(),
            resolver_file
        );
    }

    println!();
    println!("Test with: dig git.{}", zone);

    Ok(())
}

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

    if let Some(ref out) = output {
        if out.status.success() {
            let json_str = String::from_utf8_lossy(&out.stdout);
            for line in json_str.lines() {
                if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(line) {
                    if let Some(addr) = parsed["address"].as_str() {
                        if !addr.is_empty() {
                            return Some(addr.to_string());
                        }
                    }
                }
            }
        }
    }

    if cfg!(target_os = "macos") {
        if let Ok(arp_out) = Command::new("arp")
            .args(["-an"])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .output()
        {
            let arp_str = String::from_utf8_lossy(&arp_out.stdout);
            for line in arp_str.lines() {
                if line.contains("bridge100") {
                    if let Some(start) = line.find('(') {
                        if let Some(end) = line.find(')') {
                            let ip = &line[start + 1..end];
                            if !ip.is_empty() {
                                return Some(ip.to_string());
                            }
                        }
                    }
                }
            }
        }
    }

    None
}

fn dns_setup_linux(host: &str, port: u64, zone: &str) -> Result<()> {
    let resolved_running = Command::new("systemctl")
        .args(["is-active", "systemd-resolved"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim() == "active")
        .unwrap_or(false);

    if resolved_running {
        dns_setup_systemd_resolved(host, port, zone)
    } else {
        println!("{} systemd-resolved is not running", style(">>>").yellow());
        println!();
        println!("Please configure your DNS resolver manually.");
        println!("See: cata lab dns (for instructions)");
        Ok(())
    }
}

fn dns_setup_systemd_resolved(host: &str, port: u64, zone: &str) -> Result<()> {
    if !zone_is_shell_safe(zone) {
        bail!("Refusing to configure DNS: zone '{zone}' contains unexpected characters");
    }

    let target = resolved_drop_in(host, port, zone);
    let desired = format!(
        "[Resolve]\nDNS={}:{}\nDomains=~{}\n",
        host, port, target.domains
    );

    let superseded = target
        .shared
        .then(|| per_zone_conf(zone))
        .filter(|p| std::path::Path::new(p).exists());

    let matches = fs::read_to_string(&target.path)
        .map(|c| c == desired)
        .unwrap_or(false);

    if matches && superseded.is_none() {
        println!(
            "{} DNS resolver already configured at {}",
            style(">>>").green(),
            target.path
        );
        return Ok(());
    }

    println!("{} Creating {}...", style(">>>").cyan(), target.path);

    let mut script = format!(
        "set -e\nmkdir -p {RESOLVED_CONF_DIR}\ncat > {}\n",
        target.path
    );
    if let Some(ref stale) = superseded {
        println!(
            "{} Superseding per-zone {} with the shared drop-in",
            style(">>>").cyan(),
            stale
        );
        script.push_str(&format!("rm -f {stale}\n"));
    }
    script.push_str("systemctl restart systemd-resolved\n");

    let mut sh = Command::new("sudo")
        .args(["sh", "-c", &script])
        .stdin(Stdio::piped())
        .spawn()
        .context("Failed to run sudo sh")?;

    if let Some(stdin) = sh.stdin.as_mut() {
        stdin.write_all(desired.as_bytes())?;
    }
    drop(sh.stdin.take());

    let status = sh.wait()?;
    if !status.success() {
        bail!("Failed to write {}", target.path);
    }

    println!(
        "{} DNS resolver configured at {}",
        style(">>>").green(),
        target.path
    );
    if target.shared {
        println!("    Routes all of *.test, with no further sudo for any other lab.");
    }
    println!();
    println!("Test with: dig git.{}", zone);

    Ok(())
}

pub async fn dns_teardown(zone: &str, _docker_subnet: &str) -> Result<()> {
    println!(
        "{} Removing DNS configuration for *.{}",
        style(">>>").cyan(),
        zone
    );

    if cfg!(target_os = "macos") {
        dns_teardown_macos(zone)
    } else {
        dns_teardown_linux(zone)
    }
}

fn dns_teardown_macos(zone: &str) -> Result<()> {
    let resolver_file = format!("/etc/resolver/{}", zone);

    if std::path::Path::new(&resolver_file).exists() {
        println!("{} Removing {}...", style(">>>").cyan(), resolver_file);

        let rm_status = Command::new("sudo")
            .args(["rm", "-f", &resolver_file])
            .status()
            .context("Failed to run sudo rm")?;

        if !rm_status.success() {
            bail!("Failed to remove {}", resolver_file);
        }
    }

    println!("{} DNS configuration removed", style(">>>").green());

    Ok(())
}

fn dns_teardown_linux(zone: &str) -> Result<()> {
    if !zone_is_shell_safe(zone) {
        bail!("Refusing to touch DNS config: zone '{zone}' contains unexpected characters");
    }

    let conf_file = per_zone_conf(zone);

    if !std::path::Path::new(&conf_file).exists() {
        if zone.ends_with(".test") && std::path::Path::new(SHARED_TEST_CONF).exists() {
            println!(
                "{} Leaving {} in place (shared by every *.test lab)",
                style(">>>").yellow(),
                SHARED_TEST_CONF
            );
            println!("    Remove it with: sudo rm {SHARED_TEST_CONF}");
            return Ok(());
        }
        println!(
            "{} No resolver configuration found at {}",
            style(">>>").yellow(),
            conf_file
        );
        return Ok(());
    }

    println!("{} Removing {}...", style(">>>").cyan(), conf_file);

    let rm_status = Command::new("sudo")
        .args(["rm", "-f", &conf_file])
        .status()
        .context("Failed to run sudo rm")?;

    if !rm_status.success() {
        bail!("Failed to remove {}", conf_file);
    }

    println!("{} Restarting systemd-resolved...", style(">>>").cyan());

    let restart_status = Command::new("sudo")
        .args(["systemctl", "restart", "systemd-resolved"])
        .status()
        .context("Failed to restart systemd-resolved")?;

    if !restart_status.success() {
        println!(
            "{} Failed to restart systemd-resolved (may need manual restart)",
            style("Warning:").yellow()
        );
    }

    println!("{} DNS configuration removed", style(">>>").green());

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_test_zones_share_one_drop_in() {
        for zone in ["minimal.test", "homelab.test", "mesh.test"] {
            let d = resolved_drop_in("127.0.0.1", DEFAULT_DNS_HOST_PORT, zone);
            assert!(d.shared, "{zone} should use the shared drop-in");
            assert_eq!(d.path, SHARED_TEST_CONF);
            assert_eq!(d.domains, "test");
        }
    }

    #[test]
    fn a_non_default_port_keeps_its_own_drop_in() {
        let d = resolved_drop_in("127.0.0.1", 5399, "minimal.test");
        assert!(!d.shared);
        assert_eq!(d.path, "/etc/systemd/resolved.conf.d/minimal-test.conf");
        assert_eq!(d.domains, "minimal.test");
    }

    #[test]
    fn a_zone_outside_test_keeps_its_own_drop_in() {
        let d = resolved_drop_in("127.0.0.1", DEFAULT_DNS_HOST_PORT, "lab.example.com");
        assert!(!d.shared);
        assert_eq!(d.path, "/etc/systemd/resolved.conf.d/lab-example-com.conf");
    }

    #[test]
    fn a_non_loopback_resolver_keeps_its_own_drop_in() {
        let d = resolved_drop_in("172.20.0.1", DEFAULT_DNS_HOST_PORT, "minimal.test");
        assert!(!d.shared);
    }

    #[test]
    fn shell_metacharacters_in_a_zone_are_rejected() {
        assert!(zone_is_shell_safe("minimal.test"));
        assert!(!zone_is_shell_safe(""));
        assert!(!zone_is_shell_safe("a.test; rm -rf /"));
        assert!(!zone_is_shell_safe("a.test$(id)"));
        assert!(!zone_is_shell_safe("a.test/../../etc/passwd"));
    }
}

use std::fs;
use std::process::Command;

use anyhow::{Context, Result, bail};
use console::style;

use crate::config::Context as CataContext;
use crate::io::process::{run_capture, run_interactive};

use super::network::get_colima_vm_ip;

pub const RESOLVED_CONF_DIR: &str = "/etc/systemd/resolved.conf.d";

const SHARED_TEST_CONF: &str = "/etc/systemd/resolved.conf.d/catallaxy-test.conf";

const DEFAULT_DNS_HOST_PORT: u64 = 5354;

pub struct ResolvedDropIn {
    pub path: String,
    pub domains: String,
    pub shared: bool,
}

fn per_zone_conf(zone: &str) -> String {
    format!("{}/{}.conf", RESOLVED_CONF_DIR, zone.replace('.', "-"))
}

pub fn resolved_drop_in(host: &str, port: u64, zone: &str) -> ResolvedDropIn {
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

fn zone_is_well_formed(zone: &str) -> bool {
    !zone.is_empty()
        && zone
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-' || c == '_')
}

pub async fn dns_setup(ctx: &CataContext, host: &str, port: u64, zone: &str) -> Result<()> {
    println!(
        "{} Setting up DNS resolution for *.{}",
        style(">>>").cyan(),
        zone
    );

    if cfg!(target_os = "macos") {
        dns_setup_macos(ctx, host, port, zone)
    } else {
        dns_setup_linux(ctx, host, port, zone)
    }
}

fn install_resolver_file(
    ctx: &CataContext,
    dns_host: &str,
    port: u64,
    resolver_file: &str,
) -> Result<()> {
    let staged = tempfile::Builder::new()
        .prefix("cata-resolver-")
        .tempfile()
        .context("staging the resolver file")?;
    fs::write(
        staged.path(),
        format!("nameserver {dns_host}\nport {port}\n"),
    )
    .context("writing the staged resolver file")?;

    let mut install = Command::new("sudo");
    install
        .args(["install", "-m", "0644"])
        .arg(staged.path())
        .arg(resolver_file);
    run_interactive(&mut install, ctx).with_context(|| format!("installing {resolver_file}"))
}

fn dns_setup_macos(ctx: &CataContext, host: &str, port: u64, zone: &str) -> Result<()> {
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
            install_resolver_file(ctx, &dns_host, port, &resolver_file)?;
            println!(
                "{} DNS resolver updated at {}",
                style(">>>").green(),
                resolver_file
            );
        }
    } else {
        println!("{} Creating {}...", style(">>>").cyan(), resolver_file);

        let mut mkdir = Command::new("sudo");
        mkdir.args(["mkdir", "-p", resolver_dir]);
        run_interactive(&mut mkdir, ctx).with_context(|| format!("creating {resolver_dir}"))?;

        install_resolver_file(ctx, &dns_host, port, &resolver_file)?;

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

fn dns_setup_linux(ctx: &CataContext, host: &str, port: u64, zone: &str) -> Result<()> {
    let mut is_active = Command::new("systemctl");
    is_active.args(["is-active", "systemd-resolved"]);
    let resolved_running = run_capture(&mut is_active, ctx)
        .map(|o| o.trim() == "active")
        .unwrap_or(false);

    if resolved_running {
        dns_setup_systemd_resolved(ctx, host, port, zone)
    } else {
        println!("{} systemd-resolved is not running", style(">>>").yellow());
        println!();
        println!("Please configure your DNS resolver manually.");
        println!("See: cata lab dns (for instructions)");
        Ok(())
    }
}

fn dns_setup_systemd_resolved(ctx: &CataContext, host: &str, port: u64, zone: &str) -> Result<()> {
    if !zone_is_well_formed(zone) {
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

    let staged = tempfile::Builder::new()
        .prefix("cata-resolved-")
        .suffix(".conf")
        .tempfile()
        .context("staging the resolver drop-in")?;
    fs::write(staged.path(), desired.as_bytes())
        .with_context(|| format!("writing staged drop-in {}", staged.path().display()))?;

    let mut mkdir = Command::new("sudo");
    mkdir.args(["mkdir", "-p", RESOLVED_CONF_DIR]);
    run_interactive(&mut mkdir, ctx).with_context(|| format!("creating {RESOLVED_CONF_DIR}"))?;

    let mut install = Command::new("sudo");
    install
        .args(["install", "-m", "0644"])
        .arg(staged.path())
        .arg(&target.path);
    run_interactive(&mut install, ctx).with_context(|| format!("installing {}", target.path))?;

    if let Some(ref stale) = superseded {
        println!(
            "{} Superseding per-zone {} with the shared drop-in",
            style(">>>").cyan(),
            stale
        );
        let mut rm = Command::new("sudo");
        rm.args(["rm", "-f", stale]);
        run_interactive(&mut rm, ctx).with_context(|| format!("removing {stale}"))?;
    }

    let mut restart = Command::new("sudo");
    restart.args(["systemctl", "restart", "systemd-resolved"]);
    run_interactive(&mut restart, ctx).context("restarting systemd-resolved")?;

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

pub async fn dns_teardown(ctx: &CataContext, zone: &str) -> Result<()> {
    println!(
        "{} Removing DNS configuration for *.{}",
        style(">>>").cyan(),
        zone
    );

    if cfg!(target_os = "macos") {
        dns_teardown_macos(ctx, zone)
    } else {
        dns_teardown_linux(ctx, zone)
    }
}

fn dns_teardown_macos(ctx: &CataContext, zone: &str) -> Result<()> {
    let resolver_file = format!("/etc/resolver/{}", zone);

    if std::path::Path::new(&resolver_file).exists() {
        println!("{} Removing {}...", style(">>>").cyan(), resolver_file);

        let mut rm = Command::new("sudo");
        rm.args(["rm", "-f", &resolver_file]);
        run_interactive(&mut rm, ctx).with_context(|| format!("removing {resolver_file}"))?;
    }

    println!("{} DNS configuration removed", style(">>>").green());

    Ok(())
}

fn dns_teardown_linux(ctx: &CataContext, zone: &str) -> Result<()> {
    if !zone_is_well_formed(zone) {
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

    let mut rm = Command::new("sudo");
    rm.args(["rm", "-f", &conf_file]);
    run_interactive(&mut rm, ctx).with_context(|| format!("removing {conf_file}"))?;

    println!("{} Restarting systemd-resolved...", style(">>>").cyan());

    let mut restart = Command::new("sudo");
    restart.args(["systemctl", "restart", "systemd-resolved"]);
    if run_interactive(&mut restart, ctx).is_err() {
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
    fn a_zone_that_is_not_a_hostname_is_rejected() {
        assert!(zone_is_well_formed("minimal.test"));
        assert!(!zone_is_well_formed(""));
        assert!(!zone_is_well_formed("a.test; rm -rf /"));
        assert!(!zone_is_well_formed("a.test$(id)"));
        assert!(!zone_is_well_formed("a.test/../../etc/passwd"));
    }
}

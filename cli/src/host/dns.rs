use anyhow::{Context, Result, bail};
use console::style;

use crate::io;

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

fn shares_the_test_tld(host: &str, port: u64, zone: &str) -> bool {
    host == "127.0.0.1" && port == DEFAULT_DNS_HOST_PORT && zone.ends_with(".test")
}

pub fn resolved_drop_in(host: &str, port: u64, zone: &str) -> ResolvedDropIn {
    if shares_the_test_tld(host, port, zone) {
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

pub fn macos_resolver_file(host: &str, port: u64, zone: &str) -> ResolvedDropIn {
    let domains = if shares_the_test_tld(host, port, zone) {
        "test".to_string()
    } else {
        zone.to_string()
    };

    ResolvedDropIn {
        path: format!("/etc/resolver/{domains}"),
        shared: domains == "test",
        domains,
    }
}

fn zone_is_well_formed(zone: &str) -> bool {
    !zone.is_empty()
        && zone
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-' || c == '_')
}

pub async fn dns_setup(host: &str, port: u64, zone: &str) -> Result<()> {
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

fn install_resolver_file(dns_host: &str, port: u64, resolver_file: &str) -> Result<()> {
    let staged = tempfile::Builder::new()
        .prefix("cata-resolver-")
        .tempfile()
        .context("staging the resolver file")?;
    io::fs::write(
        staged.path(),
        format!("nameserver {dns_host}\nport {port}\n"),
    )
    .context("writing the staged resolver file")?;

    io::sudo::install_file(staged.path(), resolver_file)
}

fn dns_setup_macos(host: &str, port: u64, zone: &str) -> Result<()> {
    let dns_host = get_colima_vm_ip().unwrap_or_else(|| host.to_string());

    let resolver_dir = "/etc/resolver";
    let target = macos_resolver_file(&dns_host, port, zone);
    let resolver_file = target.path.clone();

    if target.shared {
        println!(
            "{} Using the shared resolver for the whole .test TLD, so every \
             *.test lab on this machine is covered by this one file.",
            style(">>>").dim(),
        );
    }

    if std::path::Path::new(&resolver_file).exists() {
        let content = io::fs::read_to_string(&resolver_file).unwrap_or_default();
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
            install_resolver_file(&dns_host, port, &resolver_file)?;
            println!(
                "{} DNS resolver updated at {}",
                style(">>>").green(),
                resolver_file
            );
        }
    } else {
        println!("{} Creating {}...", style(">>>").cyan(), resolver_file);

        io::sudo::make_directory(resolver_dir)?;

        install_resolver_file(&dns_host, port, &resolver_file)?;

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

fn dns_setup_linux(host: &str, port: u64, zone: &str) -> Result<()> {
    if io::systemd::is_active("systemd-resolved") {
        return dns_setup_systemd_resolved(host, port, zone);
    }

    let drop_in = resolved_drop_in(host, port, zone);
    bail!(
        "systemd-resolved is not running, so there is nothing here to configure \
         and nothing was written.\n    \
         `cata lab dns` prints the dnsmasq and NixOS routes as well. For dnsmasq:\n      \
         server=/{zone}/{host}#{port}\n    \
         The equivalent systemd-resolved drop-in, once it is running, is {}.\n    \
         Nothing else needs this: the lab's own clusters resolve through their own \
         DNS, and `cata lab verify` reaches lab hostnames without the host resolver.",
        drop_in.path,
    )
}

fn dns_setup_systemd_resolved(host: &str, port: u64, zone: &str) -> Result<()> {
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

    let matches = io::fs::read_to_string(&target.path)
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
    io::fs::write(staged.path(), desired.as_bytes())
        .with_context(|| format!("writing staged drop-in {}", staged.path().display()))?;

    io::sudo::make_directory(RESOLVED_CONF_DIR)?;
    io::sudo::install_file(staged.path(), &target.path)?;

    if let Some(ref stale) = superseded {
        println!(
            "{} Superseding per-zone {} with the shared drop-in",
            style(">>>").cyan(),
            stale
        );
        io::sudo::remove_file(stale)?;
    }

    io::systemd::restart("systemd-resolved")?;

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

pub async fn dns_teardown(zone: &str) -> Result<()> {
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
    if !zone_is_well_formed(zone) {
        bail!("Refusing to touch DNS config: zone '{zone}' contains unexpected characters");
    }

    let resolver_file = format!("/etc/resolver/{}", zone);

    if std::path::Path::new(&resolver_file).exists() {
        println!("{} Removing {}...", style(">>>").cyan(), resolver_file);

        io::sudo::remove_file(&resolver_file)?;
        println!("{} DNS configuration removed", style(">>>").green());
        return Ok(());
    }

    println!(
        "{} Nothing to remove for '{zone}'. A *.test lab resolves through \
         /etc/resolver/test, which is shared by every *.test lab on this \
         machine, so tearing this one down leaves it in place.",
        style(">>>").green(),
    );

    Ok(())
}

fn dns_teardown_linux(zone: &str) -> Result<()> {
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

    io::sudo::remove_file(&conf_file)?;

    println!("{} Restarting systemd-resolved...", style(">>>").cyan());

    if io::systemd::restart("systemd-resolved").is_err() {
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
    fn macos_shares_one_resolver_file_for_the_test_tld() {
        for zone in ["minimal.test", "homelab.test", "mesh.test"] {
            let r = macos_resolver_file("127.0.0.1", DEFAULT_DNS_HOST_PORT, zone);
            assert!(r.shared, "{zone} should share the .test resolver");
            assert_eq!(r.path, "/etc/resolver/test");
        }
    }

    #[test]
    fn macos_keeps_a_per_zone_resolver_when_it_cannot_share() {
        let non_test = macos_resolver_file("127.0.0.1", DEFAULT_DNS_HOST_PORT, "lab.example.com");
        assert!(!non_test.shared);
        assert_eq!(non_test.path, "/etc/resolver/lab.example.com");

        let odd_port = macos_resolver_file("127.0.0.1", 5399, "minimal.test");
        assert!(!odd_port.shared);
        assert_eq!(odd_port.path, "/etc/resolver/minimal.test");
    }

    #[test]
    fn both_platforms_agree_on_when_the_test_tld_is_shared() {
        for (host, port, zone) in [
            ("127.0.0.1", DEFAULT_DNS_HOST_PORT, "minimal.test"),
            ("127.0.0.1", 5399, "minimal.test"),
            ("127.0.0.1", DEFAULT_DNS_HOST_PORT, "lab.example.com"),
            ("172.20.0.1", DEFAULT_DNS_HOST_PORT, "minimal.test"),
        ] {
            assert_eq!(
                resolved_drop_in(host, port, zone).shared,
                macos_resolver_file(host, port, zone).shared,
                "{host}:{port} {zone} should be shared on both platforms or neither"
            );
        }
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

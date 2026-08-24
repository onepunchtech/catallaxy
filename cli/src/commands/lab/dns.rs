use anyhow::{Result, bail};
use console::style;

use crate::config::Context as CataContext;
use crate::host;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DnsAction {
    Setup,
    Teardown,
    Show,
}

impl DnsAction {
    pub fn of(setup: bool, teardown: bool) -> Result<Self> {
        match (setup, teardown) {
            (true, true) => {
                bail!("--setup and --teardown ask for opposite things; pass one of them")
            }
            (true, false) => Ok(DnsAction::Setup),
            (false, true) => Ok(DnsAction::Teardown),
            (false, false) => Ok(DnsAction::Show),
        }
    }
}

pub fn dns(ctx: &CataContext, name: &str, action: DnsAction) -> Result<()> {
    let lab = crate::io::nix::get_lab_spec(ctx, name)?;

    let Some(dns_info) = lab.dns_info.as_ref() else {
        println!(
            "{} No DNS configured (enable lab.dns to use local DNS resolution)",
            style(">>>").yellow()
        );
        return Ok(());
    };
    let host = dns_info.host.as_str();
    let port = u64::from(dns_info.port);
    let zone = dns_info.zone.as_str();

    match action {
        DnsAction::Teardown => return host::dns::dns_teardown(zone),
        DnsAction::Setup => return host::dns::dns_setup(host, port, zone),
        DnsAction::Show => {}
    }

    println!("{} Lab DNS Configuration", style("catallaxy").cyan().bold());
    println!();
    println!("DNS Server: {host}:{port}");
    println!("Zone: {zone}");
    println!();
    println!("To resolve *.{zone} from your terminal:");
    println!();

    let resolver = host::dns::macos_resolver_file(host, port, zone);
    println!("{}", style("macOS:").bold());
    println!("  sudo mkdir -p /etc/resolver");
    println!(
        "  echo -e \"nameserver {}\\nport {}\" | sudo tee {}",
        host, port, resolver.path
    );
    if resolver.shared {
        println!("  (one resolver file covers every *.test lab, install it once)");
    }
    println!();

    let drop_in = host::dns::resolved_drop_in(host, port, zone);
    println!("{}", style("Linux (systemd-resolved):").bold());
    println!("  sudo mkdir -p {}", host::dns::RESOLVED_CONF_DIR);
    println!("  cat <<EOF | sudo tee {}", drop_in.path);
    println!("  [Resolve]");
    println!("  DNS={host}:{port}");
    println!("  Domains=~{}", drop_in.domains);
    println!("  EOF");
    println!("  sudo systemctl restart systemd-resolved");
    if drop_in.shared {
        println!("  (one drop-in covers every *.test lab, install it once)");
    }
    println!();

    println!("{}", style("NixOS (survives a rebuild):").bold());
    println!("  imports = [ catallaxy.nixosModules.hostDns ];");
    println!("  services.resolved.enable = true;");
    println!("  services.catallaxy.hostDns = {{");
    println!("    enable = true;");
    println!("    zones.\"{zone}\" = {{ host = \"{host}\"; port = {port}; }};");
    println!("  }};");
    println!("  (the sudo routes above are reverted by the next nixos-rebuild)");
    println!();

    println!("{}", style("Linux (dnsmasq):").bold());
    println!("  Add to /etc/dnsmasq.conf:");
    println!("  server=/{zone}/{host}#{port}");
    println!();

    println!("{}", style("Test:").bold());
    println!("  dig @{host} -p {port} git.{zone}");
    println!();

    println!("{}", style("Auto-configure:").bold());
    println!("  cata lab dns --setup     # Write it now with sudo");
    println!("  cata lab dns --teardown  # Remove what --setup wrote");

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_flag_selects_its_own_action_and_neither_means_show() {
        assert_eq!(DnsAction::of(true, false).unwrap(), DnsAction::Setup);
        assert_eq!(DnsAction::of(false, true).unwrap(), DnsAction::Teardown);
        assert_eq!(DnsAction::of(false, false).unwrap(), DnsAction::Show);
    }

    #[test]
    fn asking_for_both_at_once_is_refused_rather_than_silently_picking_one() {
        let err = DnsAction::of(true, true).unwrap_err().to_string();
        assert!(err.contains("--setup and --teardown"), "{err}");
    }
}

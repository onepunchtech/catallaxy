use anyhow::{Result, bail};
use console::style;

use crate::config::Context as CataContext;
use crate::domain::{LabSpec, subnet};
use crate::io;
use crate::plan::{Direction, execute};

pub async fn run(
    ctx: &CataContext,
    name: &str,
    dry_run: bool,
    up_to: Option<String>,
) -> Result<()> {
    if !dry_run {
        preflight(ctx, name)?;
    }
    execute(ctx, name, dry_run, Direction::Deploy, up_to.as_deref()).await
}

fn preflight(ctx: &CataContext, name: &str) -> Result<()> {
    io::process::check_required_tools()?;

    if !io::docker::daemon_reachable() {
        bail!(
            "the docker daemon is not reachable, and every cluster and host service \
             this lab needs runs on it. Start docker (or check DOCKER_HOST) and try again."
        );
    }

    let lab = io::nix::get_lab_spec(ctx, name)?;

    refuse_colliding_subnet(name, &lab)?;

    refuse_taken_ports(name, &lab)?;

    println!("{} Preflight passed", style(">>>").green());
    Ok(())
}

fn refuse_taken_ports(name: &str, lab: &LabSpec) -> Result<()> {
    let ours: Vec<&str> = lab
        .services
        .values()
        .map(|s| s.container.as_str())
        .collect();

    let mut taken: Vec<String> = Vec::new();
    for (service, port) in declared_host_ports(lab) {
        let publishers = io::docker::containers_publishing(port);
        let holders: Vec<&String> = publishers
            .iter()
            .filter(|c| !ours.contains(&c.as_str()))
            .collect();

        if !holders.is_empty() {
            taken.push(format!(
                "  port {port} ({service}) is published by {}",
                holders
                    .iter()
                    .map(|h| h.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
            continue;
        }

        // Past the check above, every publisher is one of ours, so this is
        // just "is anything publishing it". Re-running a lab that is already
        // up must not look like a conflict.
        let ours_have_it = !publishers.is_empty();

        if !ours_have_it && !port_is_free(port) {
            taken.push(format!(
                "  port {port} ({service}) is held by something on this host that is \
                 not a container"
            ));
        }
    }

    if taken.is_empty() {
        return Ok(());
    }

    bail!(
        "lab '{name}' needs host ports that something else already publishes:\n{}\n\
         Two containers cannot bind the same host port. Nothing was started.\n    \
         The lab's host services take their ports from `lab.proxy.httpPort`, \
         `lab.proxy.httpsPort`, `lab.dns.hostPort` and `lab.registry.port`. \
         Give this lab its own where they clash, and two labs can run side by side; \
         their container names are already derived from the lab name.",
        taken.join("\n"),
    )
}

fn declared_host_ports(lab: &LabSpec) -> Vec<(String, u16)> {
    let mut seen = std::collections::BTreeSet::new();

    lab.services
        .iter()
        .flat_map(|(name, svc)| {
            svc.ports
                .iter()
                .filter_map(move |mapping| host_port_of(mapping).map(|port| (name.clone(), port)))
        })
        .filter(|(_, port)| seen.insert(*port))
        .collect()
}

fn port_is_free(port: u16) -> bool {
    use std::net::{Ipv4Addr, SocketAddrV4, TcpListener, UdpSocket};

    let addr = SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, port);
    TcpListener::bind(addr).is_ok() && UdpSocket::bind(addr).is_ok()
}

pub fn host_port_of(mapping: &str) -> Option<u16> {
    let (host, _container) = mapping.split('/').next()?.split_once(':')?;
    host.parse::<u16>().ok()
}

fn refuse_colliding_subnet(name: &str, lab: &LabSpec) -> Result<()> {
    let taken = io::docker::network_subnets();
    let ours = lab.network.docker_subnet.as_str();

    let existing_lab_network = io::docker::network_subnets_of(&lab.network.name);
    let collisions: Vec<&str> = subnet::colliding(ours, &taken)
        .into_iter()
        .filter(|c| !existing_lab_network.iter().any(|own| own == c))
        .collect();

    if collisions.is_empty() {
        return Ok(());
    }

    let suggestion = subnet::first_free_16(&taken)
        .map(|free| format!("\n    {free} is free on this machine right now."))
        .unwrap_or_default();

    bail!(
        "lab '{name}' wants the docker subnet {ours}, which overlaps a network that \
         already exists here:\n  {}\n\
         A docker network owns its subnet exclusively, so creating this one would \
         fail. Nothing was started.\n    \
         Set `lab.network.dockerSubnet` in this lab's env module to a range nothing \
         else claims.{suggestion}",
        collisions.join("\n  "),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_plain_mapping_yields_its_host_port() {
        assert_eq!(host_port_of("80:80"), Some(80));
        assert_eq!(host_port_of("5354:53"), Some(5354));
    }

    #[test]
    fn a_protocol_suffix_is_not_part_of_the_port() {
        assert_eq!(host_port_of("5354:53/udp"), Some(5354));
        assert_eq!(host_port_of("5354:53/tcp"), Some(5354));
    }

    #[test]
    fn a_mapping_it_cannot_read_yields_nothing_rather_than_a_wrong_port() {
        for bad in ["", "notaport:80", "80", "-1:80"] {
            assert_eq!(host_port_of(bad), None, "{bad}");
        }
    }
}

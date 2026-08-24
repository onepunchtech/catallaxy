use anyhow::{Result, bail};
use console::style;

use crate::config::Context as CataContext;
use crate::domain::port_mapping::{contends_across_labs, host_port_of};
use crate::domain::{LabSpec, subnet};
use crate::io;
use crate::plan::{Direction, execute};

pub async fn run(
    ctx: &CataContext,
    name: &str,
    dry_run: bool,
    up_to: Option<String>,
    infra: bool,
) -> Result<()> {
    if !dry_run {
        preflight(ctx, name)?;
    }
    execute(
        ctx,
        name,
        dry_run,
        Direction::Deploy,
        up_to.as_deref(),
        infra,
    )
    .await
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

    refuse_legacy_router(&lab)?;

    crate::host::state::write_lab_record(&crate::domain::lab_record::LabRecord::of(
        &lab,
        ctx.flake_uri(),
    ))?;

    println!("{} Preflight passed", style(">>>").green());
    Ok(())
}

/// The BGP router used to be named `catallaxy-router`, with no lab in it.
///
/// It is host-networked and binds BGP/179 on the host, so starting the
/// per-lab one alongside it gives two FRR daemons contending for the same
/// port, and the failure shows up far from its cause. `lab destroy` will
/// never remove the old one either, because teardown iterates the current
/// spec and that name is no longer in it.
const LEGACY_ROUTER: &str = "catallaxy-router";

/// Which lab a container holding one of our ports belongs to.
///
/// The label is authoritative; the name shape covers containers created
/// before catallaxy recorded provenance.
fn describe_holder(container: &str) -> String {
    if let Some(lab) = io::docker::container_label(container, crate::domain::provenance::LAB) {
        let flake = io::docker::container_label(container, crate::domain::provenance::FLAKE)
            .map(|f| format!(" from {f}"))
            .unwrap_or_default();
        return format!("which belongs to lab '{lab}'{flake}");
    }
    match crate::domain::inventory::lab_from_container_name(container) {
        Some(lab) => format!("which looks like lab '{lab}'"),
        None => "which no lab claims; `cata lab list` shows what is here".to_string(),
    }
}

fn refuse_legacy_router(lab: &LabSpec) -> Result<()> {
    let declares_router = lab
        .services
        .values()
        .any(|s| s.container.ends_with("-router"));

    if !declares_router || !io::docker::container_exists(LEGACY_ROUTER) {
        return Ok(());
    }

    bail!(
        "'{LEGACY_ROUTER}' is still running here. It is the BGP router from before \
         the container carried a lab name, and it binds BGP/179 on the host \
         network, so starting this lab's router beside it gives two FRR daemons \
         contending for the same port. Nothing was started.\n    \
         No lab claims it, so remove it with:\n      \
         cata lab cleanup --orphans"
    )
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
            for holder in &holders {
                taken.push(format!(
                    "  port {port} ({service}) is published by {holder}, {}",
                    describe_holder(holder)
                ));
            }
            continue;
        }

        // Past the check above, every publisher is one of ours, so this is
        // just "is anything publishing it". Re-running a lab that is already
        // up must not look like a conflict.
        let ours_have_it = !publishers.is_empty();

        if !ours_have_it && port_state(port) == PortState::Taken {
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
         If the other lab is finished with, remove what it left here:\n      \
         cata lab cleanup <lab>          # `cata lab list` names them\n    \
         If both are wanted at once, give this one its own ports: \
         `lab.proxy.httpPort`, `lab.proxy.httpsPort`, `lab.dns.hostPort` and \
         `lab.registry.port`. Their container names already carry the lab name, \
         so only the ports clash.",
        taken.join("\n"),
    )
}

fn declared_host_ports(lab: &LabSpec) -> Vec<(String, u16)> {
    let mut seen = std::collections::BTreeSet::new();

    let services = lab.services.iter().flat_map(|(name, svc)| {
        svc.ports
            .iter()
            .filter(|mapping| contends_across_labs(mapping))
            .filter_map(move |mapping| host_port_of(mapping).map(|port| (name.clone(), port)))
    });

    // A cluster publishes host ports too, and this used to look only at
    // `lab.services`. A clash there was found by k3d or talosctl partway
    // through building the cluster, after the network and the host services
    // were already up, rather than by the preflight that exists to say
    // "nothing was started".
    let clusters = lab.clusters.iter().flat_map(|(name, cluster)| {
        let k3d = cluster.provisioner_config.k3d.ports.iter();
        let talos = cluster.provisioner_config.talos.exposed_ports.iter();
        k3d.chain(talos)
            .filter_map(move |mapping| host_port_of(mapping).map(|port| (name.clone(), port)))
    });

    services
        .chain(clusters)
        .filter(|(_, port)| seen.insert(*port))
        .collect()
}

/// What a bind attempt tells us about a port.
///
/// Binding is not a yes/no question. A port below 1024 refuses a non-root
/// bind with `PermissionDenied` whether or not anything holds it, and docker
/// publishes those ports as root regardless. Reading that refusal as "taken"
/// made `lab up` refuse every lab that uses port 80, naming a conflict that
/// did not exist.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PortState {
    Free,
    Taken,
    CannotTell,
}

pub fn classify_bind(result: Result<(), std::io::ErrorKind>) -> PortState {
    match result {
        Ok(()) => PortState::Free,
        Err(std::io::ErrorKind::AddrInUse) => PortState::Taken,
        Err(_) => PortState::CannotTell,
    }
}

fn port_state(port: u16) -> PortState {
    classify_bind(io::net::try_bind(port))
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

    // A port below 1024 refuses a non-root bind with PermissionDenied whether
    // or not anything holds it, and docker publishes it as root regardless.
    // Reading that as "taken" made lab up refuse a lab that would have worked.
    #[test]
    fn a_privileged_port_we_may_not_bind_is_not_a_conflict() {
        assert_eq!(
            classify_bind(Err(std::io::ErrorKind::PermissionDenied)),
            PortState::CannotTell
        );
    }

    #[test]
    fn only_an_address_already_in_use_is_a_conflict() {
        assert_eq!(
            classify_bind(Err(std::io::ErrorKind::AddrInUse)),
            PortState::Taken
        );
    }

    #[test]
    fn a_port_that_binds_is_free() {
        assert_eq!(classify_bind(Ok(())), PortState::Free);
    }

    #[test]
    fn no_other_error_is_read_as_a_conflict() {
        for kind in [
            std::io::ErrorKind::AddrNotAvailable,
            std::io::ErrorKind::InvalidInput,
            std::io::ErrorKind::Other,
        ] {
            assert_eq!(classify_bind(Err(kind)), PortState::CannotTell, "{kind:?}");
        }
    }

    /// The two provisioners write a host port three different ways, and the
    /// preflight has to read all of them or it reports a clean lab and then
    /// fails inside `k3d cluster create`.
    #[test]
    fn a_host_port_is_found_in_every_shape_a_provisioner_writes_it() {
        for (mapping, expected) in [
            ("8080:80@server:0", Some(8080)),
            ("5353:53/udp@server:0", Some(5353)),
            ("8080:80/tcp", Some(8080)),
            ("127.0.0.1:8080:80", Some(8080)),
            ("172.20.0.1:443:443", Some(443)),
            ("127.0.0.1:5354:53/udp", Some(5354)),
            ("80", None),
        ] {
            assert_eq!(host_port_of(mapping), expected, "{mapping}");
        }
    }

    /// The ingress publishes on its own lab's bridge gateway as well as on
    /// loopback. Those gateway addresses are unique per lab, so treating them
    /// as contended refused to start a second lab over a port nothing shared.
    #[test]
    fn only_shared_addresses_contend_between_labs() {
        for (mapping, contends) in [
            ("8080:80", true),
            ("127.0.0.1:8080:80", true),
            ("0.0.0.0:8080:80", true),
            ("172.25.0.1:80:80", false),
            ("172.20.0.1:443:443/tcp", false),
        ] {
            assert_eq!(contends_across_labs(mapping), contends, "{mapping}");
        }
    }
}

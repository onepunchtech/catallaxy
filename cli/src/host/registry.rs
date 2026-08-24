//! What a cluster node needs on disk to pull through the lab's registry.
//!
//! Two callers wanted this: the `registry-setup` step, and `cata cluster init`
//! for a cluster stood up outside a lab deploy. The second had its own copy
//! with `let _ =` on every write, so a lab whose CA had not been minted, or
//! whose state directory was not writable, produced a cluster that pulled from
//! upstream and a run that looked clean.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use console::style;

use crate::host::services;
use crate::host::state;

/// Writes `registries.yaml`, `certs.d/` and `lab-resolv.conf` for a lab.
///
/// Returns the path to `registries.yaml`, which is what a provisioner mounts.
///
/// `zone` absent means the lab has no DNS, so there is no registry hostname to
/// trust and only the mirror config is written. `dns_ip` absent is reported
/// rather than fatal: nodes fall back to docker's resolver and lab hostnames
/// stop resolving, which is worth saying and not worth refusing a cluster for.
///
/// # Errors
///
/// If the state directory cannot be created, or any of the files cannot be
/// written, or the lab CA exists but cannot be copied.
pub fn write_node_config(
    lab_name: &str,
    port: u16,
    upstreams: &[String],
    zone: Option<&str>,
    dns_ip: Option<&str>,
) -> Result<PathBuf> {
    let state_dir = state::service_state_dir(lab_name, "registry");
    crate::io::fs::create_dir_all(&state_dir)
        .with_context(|| format!("creating {}", state_dir.display()))?;

    let registries_yaml = state_dir.join("registries.yaml");
    crate::io::fs::write(
        &registries_yaml,
        services::generate_registries_yaml(port, upstreams),
    )
    .context("writing registries.yaml")?;

    if let Some(zone) = zone {
        write_registry_trust(&state_dir, lab_name, zone)?;
    }

    match dns_ip {
        Some(ip) => {
            crate::io::fs::write(
                state_dir.join("lab-resolv.conf"),
                services::lab_resolv_conf(ip),
            )
            .context("writing lab-resolv.conf")?;
        }
        None => {
            println!(
                "{} Could not resolve lab DNS container IP; cluster nodes \
                 will fall back to Docker DNS (lab hostnames won't resolve)",
                style("Warning:").yellow(),
            );
        }
    }

    Ok(registries_yaml)
}

/// The containerd trust config for the lab's own registry hostname.
fn write_registry_trust(state_dir: &Path, lab_name: &str, zone: &str) -> Result<()> {
    let host_dir = state_dir.join("certs.d").join(format!("registry.{zone}"));
    crate::io::fs::create_dir_all(&host_dir)
        .with_context(|| format!("creating {}", host_dir.display()))?;
    crate::io::fs::write(
        host_dir.join("hosts.toml"),
        services::generate_registry_hosts_toml(zone),
    )
    .context("writing hosts.toml")?;

    let lab_ca = state::lab_ca_path(lab_name);
    if lab_ca.exists() {
        crate::io::fs::copy(&lab_ca, host_dir.join(state::CA_CERT))
            .context("copying lab CA into certs.d")?;
    } else {
        println!(
            "{} Lab CA missing at {}; registry pulls will fail until cert-generate produces it.",
            style("Warning:").yellow(),
            lab_ca.display(),
        );
    }
    Ok(())
}

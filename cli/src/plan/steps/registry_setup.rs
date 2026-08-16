use std::path::PathBuf;

use anyhow::{Context, Result};
use console::style;

use crate::domain::plan::RegistrySetupParams;
use crate::host::services;
use crate::host::state;
use crate::plan::StepContext;

pub async fn run(sctx: &StepContext<'_>, p: &RegistrySetupParams) -> Result<()> {
    let RegistrySetupParams {
        port,
        upstreams,
        zone,
    } = p;

    if sctx.dry_run {
        println!(
            "{} [dry-run] would write registries.yaml, certs.d/, and lab-resolv.conf",
            style(">>>").yellow()
        );
        return Ok(());
    }

    let lab_name = sctx.lab_name;

    let state_dir = state::service_state_dir(lab_name, "registry");
    crate::io::fs::create_dir_all(&state_dir)
        .with_context(|| format!("creating {}", state_dir.display()))?;
    let registries_yaml = services::generate_registries_yaml(*port as u16, upstreams);
    crate::io::fs::write(state_dir.join("registries.yaml"), registries_yaml)
        .context("writing registries.yaml")?;

    let certs_d = state_dir.join("certs.d");
    let host_dir = certs_d.join(format!("registry.{zone}"));
    crate::io::fs::create_dir_all(&host_dir)
        .with_context(|| format!("creating {}", host_dir.display()))?;
    crate::io::fs::write(
        host_dir.join("hosts.toml"),
        services::generate_registry_hosts_toml(zone),
    )
    .context("writing hosts.toml")?;
    let lab_ca_src = state::service_state_dir(lab_name, "proxy").join("ca.crt");
    if lab_ca_src.exists() {
        crate::io::fs::copy(&lab_ca_src, host_dir.join("ca.crt"))
            .context("copying lab CA into certs.d")?;
    } else {
        println!(
            "{} Lab CA missing at {}; registry pulls will fail until cert-generate produces it.",
            style("Warning:").yellow(),
            lab_ca_src.display(),
        );
    }

    let dns_server = sctx
        .lab
        .dns_container()
        .and_then(crate::io::docker::first_network_ip);
    match dns_server {
        Some(ip) => {
            let resolv_path: PathBuf = state_dir.join("lab-resolv.conf");
            let content = services::lab_resolv_conf(&ip);
            crate::io::fs::write(&resolv_path, content).context("writing lab-resolv.conf")?;
        }
        None => {
            println!(
                "{} Could not resolve lab DNS container IP; k3d nodes \
                 will fall back to Docker DNS (lab hostnames won't resolve)",
                style("Warning:").yellow(),
            );
        }
    }

    Ok(())
}

pub fn dns_container_of(lab: &crate::domain::LabSpec) -> Option<&str> {
    lab.services.get("dns").map(|s| s.container.as_str())
}

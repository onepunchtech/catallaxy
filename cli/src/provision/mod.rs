use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use console::style;

use crate::config::Context as CataContext;
use crate::domain::{ClusterSpec, ProvisionerKind};
use crate::io;

pub fn provisioner_cluster_name(spec: &ClusterSpec) -> &str {
    match spec.provisioner {
        ProvisionerKind::K3d => &spec.provisioner_config.k3d.cluster_name,
        ProvisionerKind::Talos => &spec.provisioner_config.docker.cluster_name,
        ProvisionerKind::Crossplane | ProvisionerKind::External => "",
    }
}

pub fn resolve_docker_host(_ctx: &CataContext, spec: &ClusterSpec) -> Result<Option<String>> {
    if !io::colima::is_macos() {
        return Ok(None);
    }

    let colima = &spec.provisioner_config.docker.colima;
    if !colima.enable {
        return Ok(None);
    }

    if io::colima::profile_running(&colima.profile) {
        println!(
            "{} Colima VM already running (profile: {})",
            style(">>>").green(),
            colima.profile
        );
    } else {
        io::colima::start(&colima.profile, colima.cpu, colima.memory, colima.disk)?;
    }

    Ok(Some(io::colima::docker_socket(&colima.profile)))
}

fn run_pre_provision_hooks(name: &str, spec: &ClusterSpec) -> Result<()> {
    for hook in &spec.lifecycle.pre_provision {
        if hook.bin.is_empty() {
            continue;
        }

        println!("{} [{name}] {}...", style(">>>").cyan(), hook.description);

        let status = io::hook::run(&hook.bin, &[], None).map_err(|e| {
            anyhow::anyhow!(
                "failed to exec preProvision hook `{}` for cluster `{name}`: {e}",
                hook.bin
            )
        })?;

        if !status.success() {
            bail!(
                "preProvision hook `{}` for cluster `{name}` failed \
                 (exit {}). See message above; the hook's stderr explains the \
                 fix.",
                hook.name,
                status.code().unwrap_or(-1)
            );
        }
    }

    Ok(())
}

pub fn provision_cluster_with_registry(
    ctx: &CataContext,
    name: &str,
    spec: &ClusterSpec,
    registries_yaml: Option<&std::path::Path>,
    lab_package: Option<&str>,
) -> Result<()> {
    let cluster_name = provisioner_cluster_name(spec).to_string();

    run_pre_provision_hooks(name, spec)?;

    match spec.provisioner {
        ProvisionerKind::K3d => {
            provision_k3d(ctx, name, &cluster_name, spec, registries_yaml, lab_package)?;
        }
        ProvisionerKind::Talos => {
            let docker_host = resolve_docker_host(ctx, spec)?;
            if io::talos::cluster_exists(&cluster_name, docker_host.as_deref()) {
                println!(
                    "{} Cluster '{name}' is already running",
                    style(">>>").green()
                );
                return Ok(());
            }

            io::talos::cluster_create(
                &cluster_name,
                spec.kubernetes.control_planes,
                spec.kubernetes.workers,
                docker_host.as_deref(),
            )?;
        }
        ProvisionerKind::Crossplane => {
            println!(
                "{} Crossplane clusters are provisioned via CAPI on the management cluster",
                style(">>>").cyan()
            );
        }
        ProvisionerKind::External => {
            println!(
                "{} External cluster '{name}', no provisioning needed",
                style(">>>").cyan()
            );
        }
    }

    Ok(())
}

pub fn stop_cluster(ctx: &CataContext, name: &str, spec: &ClusterSpec) -> Result<()> {
    let cluster_name = provisioner_cluster_name(spec).to_string();

    match spec.provisioner {
        ProvisionerKind::K3d => {
            let docker_host = resolve_docker_host(ctx, spec)?;
            if !io::k3d::cluster_exists(&cluster_name, docker_host.as_deref()) {
                println!("{} Cluster '{name}' is not running", style(">>>").green());
                return Ok(());
            }
            io::k3d::cluster_stop(&cluster_name, docker_host.as_deref())?;
        }
        ProvisionerKind::External | ProvisionerKind::Crossplane => {
            println!(
                "  {} cluster '{name}', nothing to stop locally",
                spec.provider
            );
        }
        ProvisionerKind::Talos => {
            println!("  Cluster '{name}' (talos): stop not supported, skipping");
        }
    }

    Ok(())
}

pub fn deprovision_cluster(ctx: &CataContext, name: &str, spec: &ClusterSpec) -> Result<()> {
    let cluster_name = provisioner_cluster_name(spec).to_string();

    match spec.provisioner {
        ProvisionerKind::K3d => {
            let docker_host = resolve_docker_host(ctx, spec)?;
            if !io::k3d::cluster_exists(&cluster_name, docker_host.as_deref()) {
                println!("{} Cluster '{name}' is not running", style(">>>").green());
                return Ok(());
            }
            io::k3d::cluster_destroy(&cluster_name, docker_host.as_deref())?;
        }
        ProvisionerKind::Talos => {
            let docker_host = resolve_docker_host(ctx, spec)?;
            if !io::talos::cluster_exists(&cluster_name, docker_host.as_deref()) {
                println!("{} Cluster '{name}' is not running", style(">>>").green());
                return Ok(());
            }
            io::talos::cluster_destroy(&cluster_name, docker_host.as_deref())?;
        }
        ProvisionerKind::Crossplane => {
            println!(
                "{} Crossplane clusters are deprovisioned via CAPI on the management cluster",
                style(">>>").cyan()
            );
        }
        ProvisionerKind::External => {
            println!("  External clusters cannot be deleted via cata.");
        }
    }

    Ok(())
}

fn provision_k3d(
    ctx: &CataContext,
    name: &str,
    cluster_name: &str,
    spec: &ClusterSpec,
    registries_yaml: Option<&std::path::Path>,
    lab_package: Option<&str>,
) -> Result<()> {
    let docker_host = resolve_docker_host(ctx, spec)?;
    if io::k3d::cluster_exists(cluster_name, docker_host.as_deref()) {
        println!(
            "{} Cluster '{name}' is already running",
            style(">>>").green()
        );
        io::k3d::kubeconfig_merge(cluster_name, docker_host.as_deref())?;
        report_cluster_drift(name, spec);
        return Ok(());
    }

    let k3d = &spec.provisioner_config.k3d;
    let auto_deploy = resolve_auto_deploy(ctx, name, spec, lab_package);
    let port_refs: Vec<&str> = k3d.ports.iter().map(String::as_str).collect();

    let lab_name = ctx.resolve_lab_name(None)?;
    let state_dir = crate::host::state::lab_state_dir(&lab_name);
    let extra_volumes: Vec<(String, String)> = k3d
        .extra_volumes
        .iter()
        .map(|v| {
            (
                resolve_placeholders(&v.host_path, &state_dir, name),
                v.container_path.clone(),
            )
        })
        .collect();
    refuse_missing_mounts(name, &extra_volumes)?;

    let registries_yaml_str = registries_yaml.map(|p| p.to_string_lossy().to_string());
    let registry_dir = registries_yaml.and_then(|p| p.parent().map(|d| d.to_path_buf()));
    let certs_d_str = registry_dir
        .as_ref()
        .map(|d| d.join("certs.d"))
        .filter(|p| p.exists())
        .map(|p| p.to_string_lossy().to_string());
    let resolv_conf_str = registry_dir
        .as_ref()
        .map(|d| d.join("lab-resolv.conf"))
        .filter(|p| p.exists())
        .map(|p| p.to_string_lossy().to_string());

    io::k3d::cluster_create(io::k3d::ClusterCreate {
        name: cluster_name,
        workers: spec.kubernetes.workers,
        no_traefik: k3d.no_traefik,
        no_service_lb: k3d.no_service_lb,
        no_flannel: k3d.no_flannel,
        image: k3d.image.as_deref(),
        docker_host: docker_host.as_deref(),
        registries_yaml: registries_yaml_str.as_deref(),
        certs_d: certs_d_str.as_deref(),
        resolv_conf: resolv_conf_str.as_deref(),
        service_cidr: Some(spec.network.service_subnet.as_str()),
        pod_cidr: Some(spec.network.pod_subnet.as_str()),
        auto_deploy_manifests: &auto_deploy,
        ports: &port_refs,
        network: k3d.network.as_deref(),
        extra_api_server_args: &k3d.extra_api_server_args,
        extra_volumes: &extra_volumes,
    })?;

    wait_until_answering(
        &spec.kube_context,
        &spec.provisioner_config.docker.wait_timeout,
    )?;

    Ok(())
}

fn wait_until_answering(kube_context: &str, wait_timeout: &str) -> Result<()> {
    let timeout = crate::io::kubectl::parse_timeout(wait_timeout).with_context(|| {
        format!("provisioner.docker.waitTimeout is '{wait_timeout}', which is not a duration")
    })?;

    let answered = crate::io::poll::poll_while_time_remains(
        timeout,
        std::time::Duration::from_secs(2),
        || io::kubectl::api_reachable(kube_context).then_some(()),
    );
    if answered.is_some() {
        return Ok(());
    }

    anyhow::bail!(
        "cluster was created but '{kube_context}' did not answer within {}. \
         Raise provisioner.docker.waitTimeout if the machine is slow, or check \
         `docker logs` for the server node.",
        wait_timeout,
    )
}

fn normalize_k3s_version(version: &str) -> String {
    version.replace('+', "-")
}

pub fn describe_cluster_drift(
    declared_workers: u32,
    actual_workers: u32,
    declared_image: Option<&str>,
    actual_version: Option<&str>,
) -> Vec<String> {
    let mut drift = Vec::new();

    if declared_workers != actual_workers {
        drift.push(format!(
            "cluster.kubernetes.workers is {declared_workers}, the cluster has {actual_workers}"
        ));
    }

    if let (Some(image), Some(version)) = (declared_image, actual_version) {
        let declared_version = image.rsplit(':').next().unwrap_or(image);
        if !declared_version.is_empty()
            && normalize_k3s_version(version) != normalize_k3s_version(declared_version)
        {
            drift.push(format!(
                "provisioner.k3d.image asks for {declared_version}, the nodes run {version}"
            ));
        }
    }

    drift
}

fn report_cluster_drift(name: &str, spec: &ClusterSpec) {
    let Some(nodes) = io::kubectl::node_summary(&spec.kube_context) else {
        return;
    };

    let drift = describe_cluster_drift(
        spec.kubernetes.workers,
        nodes.workers,
        spec.provisioner_config.k3d.image.as_deref(),
        nodes.kubelet_version.as_deref(),
    );

    if drift.is_empty() {
        return;
    }

    println!(
        "{} '{name}' no longer matches what the lab declares:",
        style("Warning:").yellow(),
    );
    for line in &drift {
        println!("    - {line}");
    }
    println!(
        "    `lab up` only creates a cluster that is missing; it does not reshape one \
         that exists.\n    Recreate it to converge:  cata lab destroy && cata lab up"
    );
}

fn refuse_missing_mounts(cluster_name: &str, volumes: &[(String, String)]) -> Result<()> {
    let missing: Vec<&str> = volumes
        .iter()
        .filter(|(host_path, _)| !std::path::Path::new(host_path).exists())
        .map(|(host_path, _)| host_path.as_str())
        .collect();

    if missing.is_empty() {
        return Ok(());
    }

    anyhow::bail!(
        "cluster '{cluster_name}' declares volume mounts whose host paths do not exist:\n  {}\n\
         Docker would create empty directories there and the apiserver would fail to start \
         reading them as files. Nothing was created.\n\
         A client CA comes from `cata pki init {cluster_name}`. An audit policy file has no \
         generator yet, so cluster.security.auditLogging cannot work on k3d.",
        missing.join("\n  "),
    )
}

fn resolve_placeholders(path: &str, state_dir: &std::path::Path, cluster_name: &str) -> String {
    path.replace("{{STATE_DIR}}", &state_dir.display().to_string())
        .replace(
            "{{PKI_DIR}}",
            &crate::host::state::cluster_pki_dir(cluster_name)
                .display()
                .to_string(),
        )
        .replace("{{CLUSTER_NAME}}", cluster_name)
}

fn resolve_auto_deploy(
    ctx: &CataContext,
    name: &str,
    spec: &ClusterSpec,
    lab_package: Option<&str>,
) -> Vec<(String, String)> {
    let mut auto_deploy: Vec<(String, String)> = spec
        .provisioner_config
        .k3d
        .auto_deploy_manifests
        .iter()
        .map(|m| (m.name.clone(), m.path.clone()))
        .collect();

    if !auto_deploy.is_empty() {
        let lab_pkg = if let Some(pkg) = lab_package {
            Some(pkg.to_string())
        } else if let Ok(lab_name) = ctx.resolve_lab_name(None) {
            crate::io::nix::build_lab_package(ctx, &lab_name).ok()
        } else {
            None
        };
        if let Some(lab_pkg) = lab_pkg {
            auto_deploy = auto_deploy
                .into_iter()
                .map(|(n, p)| {
                    let pkg_path = format!("{lab_pkg}/autodeploy/{name}/{n}.yaml");
                    if std::path::Path::new(&pkg_path).exists() {
                        (n, pkg_path)
                    } else {
                        (n, p)
                    }
                })
                .collect();
        }
    }

    auto_deploy
}

pub fn ensure_lab_services(ctx: &CataContext, cluster_name: &str) -> Option<PathBuf> {
    let lab_names: Result<Vec<String>> = crate::io::nix::list_labs(ctx);
    let lab_names = match lab_names {
        Ok(names) => names,
        Err(_) => return None,
    };

    for lab_name in &lab_names {
        let lab = match crate::io::nix::get_lab_spec(ctx, lab_name) {
            Ok(lab) => lab,
            Err(_) => continue,
        };

        if !lab.cluster_names.iter().any(|n| n == cluster_name) {
            continue;
        }

        for (svc_name, svc) in &lab.services {
            if let Err(e) = crate::host::services::start_service(lab_name, svc_name, svc) {
                let description = svc.description.as_str();
                println!(
                    "{} Failed to start {}: {}",
                    style("Warning:").yellow(),
                    description,
                    e
                );
            }
        }

        if let Some(port) = lab.registry_port {
            let state_dir = crate::host::state::service_state_dir(lab_name, "registry");
            if io::fs::create_dir_all(&state_dir).is_ok() {
                let path = state_dir.join("registries.yaml");
                let registry_yaml =
                    crate::host::services::generate_registries_yaml(port, &lab.registry_upstreams);
                if let Some(zone) = lab.dns_info.as_ref().map(|d| d.zone.as_str()) {
                    let host_dir = state_dir.join("certs.d").join(format!("registry.{zone}"));
                    if io::fs::create_dir_all(&host_dir).is_ok() {
                        let _ = io::fs::write(
                            host_dir.join("hosts.toml"),
                            crate::host::services::generate_registry_hosts_toml(zone),
                        );
                        let ca_src =
                            crate::host::state::service_state_dir(lab_name, "proxy").join("ca.crt");
                        if ca_src.exists() {
                            let _ = io::fs::copy(&ca_src, host_dir.join("ca.crt"));
                        }
                    }
                }
                if lab.dns_info.is_some() {
                    let dns_ip = lab.dns_container().and_then(io::docker::first_network_ip);
                    if let Some(dns_ip) = dns_ip {
                        let _ = io::fs::write(
                            state_dir.join("lab-resolv.conf"),
                            crate::host::services::lab_resolv_conf(&dns_ip),
                        );
                    }
                }
                if io::fs::write(&path, registry_yaml).is_ok() {
                    return Some(path);
                }
            }
        }
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_matching_cluster_reports_no_drift() {
        assert!(
            describe_cluster_drift(2, 2, Some("rancher/k3s:v1.31.2-k3s1"), Some("v1.31.2+k3s1"))
                .is_empty()
        );
    }

    #[test]
    fn a_worker_count_change_is_drift() {
        let drift = describe_cluster_drift(3, 0, None, None);
        assert_eq!(drift.len(), 1, "{drift:?}");
        assert!(drift[0].contains("workers is 3"), "{drift:?}");
        assert!(drift[0].contains("has 0"), "{drift:?}");
    }

    #[test]
    fn a_k3s_version_change_is_drift() {
        let drift =
            describe_cluster_drift(0, 0, Some("rancher/k3s:v1.32.0-k3s1"), Some("v1.31.2+k3s1"));
        assert_eq!(drift.len(), 1, "{drift:?}");
        assert!(drift[0].contains("v1.32.0-k3s1"), "{drift:?}");
    }

    #[test]
    fn an_unknown_running_version_is_not_reported_as_drift() {
        assert!(describe_cluster_drift(0, 0, Some("rancher/k3s:v1.32.0-k3s1"), None).is_empty());
    }
}

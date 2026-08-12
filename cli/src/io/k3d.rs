use std::process::{Command, Stdio};

use anyhow::{Context, Result};
use console::style;

use crate::config::Context as CataContext;
use crate::io::process::run_streaming;

pub struct ClusterCreate<'a> {
    pub name: &'a str,
    pub workers: u32,
    pub no_traefik: bool,
    pub no_service_lb: bool,
    pub no_flannel: bool,
    pub image: Option<&'a str>,
    pub docker_host: Option<&'a str>,
    pub registries_yaml: Option<&'a str>,
    pub certs_d: Option<&'a str>,
    pub resolv_conf: Option<&'a str>,
    pub service_cidr: Option<&'a str>,
    pub pod_cidr: Option<&'a str>,
    pub auto_deploy_manifests: &'a [(String, String)],
    pub ports: &'a [&'a str],
    pub network: Option<&'a str>,
}

pub fn cluster_create(ctx: &CataContext, opts: ClusterCreate<'_>) -> Result<()> {
    let ClusterCreate {
        name,
        workers,
        no_traefik,
        no_service_lb,
        no_flannel,
        image,
        docker_host,
        registries_yaml,
        certs_d,
        resolv_conf,
        service_cidr,
        pod_cidr,
        auto_deploy_manifests,
        ports,
        network,
    } = opts;
    println!("{} Creating k3d cluster '{name}'...", style(">>>").cyan());

    let mut cmd = Command::new("k3d");
    cmd.args(["cluster", "create", name, "--agents", &workers.to_string()]);

    if let Some(net) = network {
        cmd.args(["--network", net]);
    }

    k3s_server_args(
        &mut cmd,
        no_traefik,
        no_service_lb,
        no_flannel,
        service_cidr,
        pod_cidr,
    );
    mount_auto_deploy_manifests(&mut cmd, name, auto_deploy_manifests)?;

    for port in ports {
        cmd.args(["-p", port]);
    }

    cmd.args([
        "--volume",
        "/var/run/docker.sock:/var/run/docker.sock@server:0",
    ]);

    if let Some(path) = registries_yaml {
        cmd.args([
            "--volume",
            &format!("{}:/etc/rancher/k3s/registries.yaml@server:*", path),
        ]);
    }

    if let Some(path) = certs_d {
        cmd.args([
            "--volume",
            &format!(
                "{}:/var/lib/rancher/k3s/agent/etc/containerd/certs.d@server:*",
                path
            ),
        ]);
    }

    if let Some(path) = resolv_conf {
        cmd.args(["--volume", &format!("{path}:/etc/resolv.conf@server:*")]);
        cmd.env("K3D_FIX_DNS", "0");
    }

    if let Some(img) = image {
        cmd.args(["--image", img]);
    }
    if let Some(host) = docker_host {
        cmd.env("DOCKER_HOST", host);
    }

    run_streaming(&mut cmd, ctx)?;

    println!(
        "{} Cluster ready (context: k3d-{name})",
        style(">>>").green()
    );
    Ok(())
}

pub fn cluster_destroy(ctx: &CataContext, name: &str, docker_host: Option<&str>) -> Result<()> {
    println!("{} Destroying k3d cluster '{name}'...", style(">>>").cyan());

    let mut cmd = Command::new("k3d");
    cmd.args(["cluster", "delete", name]);

    if let Some(host) = docker_host {
        cmd.env("DOCKER_HOST", host);
    }

    run_streaming(&mut cmd, ctx)?;

    println!("{} Cluster destroyed", style(">>>").green());
    Ok(())
}

pub fn cluster_stop(ctx: &CataContext, name: &str, docker_host: Option<&str>) -> Result<()> {
    println!("{} Stopping k3d cluster '{name}'...", style(">>>").cyan());

    let mut cmd = Command::new("k3d");
    cmd.args(["cluster", "stop", name]);

    if let Some(host) = docker_host {
        cmd.env("DOCKER_HOST", host);
    }

    run_streaming(&mut cmd, ctx)?;

    println!("{} Cluster stopped", style(">>>").green());
    Ok(())
}

pub fn cluster_exists(name: &str, docker_host: Option<&str>) -> bool {
    let mut cmd = Command::new("k3d");
    cmd.args(["cluster", "get", name]);
    cmd.stdout(Stdio::null());
    cmd.stderr(Stdio::null());

    if let Some(host) = docker_host {
        cmd.env("DOCKER_HOST", host);
    }

    let status = cmd.status();
    matches!(status, Ok(s) if s.success())
}

pub fn kubeconfig_merge(name: &str, docker_host: Option<&str>) -> Result<()> {
    let mut cmd = Command::new("k3d");
    cmd.args([
        "kubeconfig",
        "merge",
        name,
        "--kubeconfig-merge-default",
        "--kubeconfig-switch-context=false",
    ]);
    cmd.stdout(Stdio::null());
    if let Some(host) = docker_host {
        cmd.env("DOCKER_HOST", host);
    }
    let status = cmd
        .status()
        .with_context(|| format!("Failed to merge kubeconfig for k3d cluster '{name}'"))?;
    if !status.success() {
        anyhow::bail!("k3d kubeconfig merge for '{name}' exited with {status}");
    }
    Ok(())
}

pub fn cluster_show(ctx: &CataContext, name: &str, docker_host: Option<&str>) -> Result<()> {
    let mut cmd = Command::new("k3d");
    cmd.args(["cluster", "get", name]);

    if let Some(host) = docker_host {
        cmd.env("DOCKER_HOST", host);
    }

    run_streaming(&mut cmd, ctx)
}

fn k3s_server_args(
    cmd: &mut Command,
    no_traefik: bool,
    no_service_lb: bool,
    no_flannel: bool,
    service_cidr: Option<&str>,
    pod_cidr: Option<&str>,
) {
    if no_traefik {
        cmd.args(["--k3s-arg", "--disable=traefik@server:*"]);
    }
    if no_service_lb {
        cmd.args(["--k3s-arg", "--disable=servicelb@server:*"]);
    }
    if no_flannel {
        cmd.args(["--k3s-arg", "--flannel-backend=none@server:*"]);
        cmd.args(["--k3s-arg", "--disable-network-policy@server:*"]);
    }

    if let Some(cidr) = service_cidr {
        cmd.args(["--k3s-arg", &format!("--service-cidr={cidr}@server:*")]);
    }
    if let Some(cidr) = pod_cidr {
        cmd.args(["--k3s-arg", &format!("--cluster-cidr={cidr}@server:*")]);
    }
}

fn mount_auto_deploy_manifests(
    cmd: &mut Command,
    name: &str,
    auto_deploy_manifests: &[(String, String)],
) -> Result<()> {
    let auto_deploy_dir = if !auto_deploy_manifests.is_empty() {
        let dir = std::env::temp_dir().join(format!("cata-autodeploy-{name}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir)?;
        Some(dir)
    } else {
        None
    };
    for (manifest_name, manifest_path) in auto_deploy_manifests {
        let host_path = if let Some(ref dir) = auto_deploy_dir {
            let dest = dir.join(format!("{manifest_name}.yaml"));
            std::fs::copy(manifest_path, &dest)
                .with_context(|| format!("Failed to copy auto-deploy manifest {manifest_path}"))?;
            dest.display().to_string()
        } else {
            manifest_path.clone()
        };
        cmd.args([
            "--volume",
            &format!(
                "{host_path}:/var/lib/rancher/k3s/server/manifests/{manifest_name}.yaml@server:*"
            ),
        ]);
    }

    Ok(())
}

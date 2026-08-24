use std::path::Path;
use std::process::{Command, Stdio};

use anyhow::{Context, Result, bail};
use console::style;

use crate::io::process::run_streaming;

pub struct ClusterCreate<'a> {
    pub name: &'a str,
    pub workers: u32,
    pub no_traefik: bool,
    pub no_service_lb: bool,
    pub no_flannel: bool,
    pub no_local_storage: bool,
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
    pub extra_api_server_args: &'a [String],
    pub extra_volumes: &'a [(String, String)],
}

/// # Errors
///
/// If an auto-deploy manifest cannot be staged into a temp directory, or `k3d`
/// cannot be spawned, or it exits non-zero. k3d's output went to the terminal,
/// so the message carries only the exit code.
pub fn cluster_create(opts: ClusterCreate<'_>) -> Result<()> {
    let ClusterCreate {
        name,
        workers,
        no_traefik,
        no_service_lb,
        no_flannel,
        no_local_storage,
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
        extra_api_server_args,
        extra_volumes,
    } = opts;
    println!("{} Creating k3d cluster '{name}'...", style(">>>").cyan());

    let mut cmd = Command::new("k3d");
    cmd.args(["cluster", "create", name, "--agents", &workers.to_string()]);

    // Both default to true, and neither was passed, so creating a cluster
    // wrote the operator's default kubeconfig and moved their current-context
    // onto the new cluster. Nothing asked for either. The lab's own file is
    // populated by `kubeconfig_merge` below.
    cmd.args([
        "--kubeconfig-update-default=false",
        "--kubeconfig-switch-context=false",
    ]);

    if let Some(net) = network {
        cmd.args(["--network", net]);
    }

    k3s_server_args(
        &mut cmd,
        Disables {
            traefik: no_traefik,
            service_lb: no_service_lb,
            flannel: no_flannel,
            local_storage: no_local_storage,
        },
        service_cidr,
        pod_cidr,
    );
    for arg in extra_api_server_args {
        cmd.args(["--k3s-arg", &format!("--kube-apiserver-arg={arg}@server:*")]);
    }
    for (host_path, container_path) in extra_volumes {
        cmd.args([
            "--volume",
            &format!("{host_path}:{container_path}@server:*"),
        ]);
    }
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
            &format!("{path}:/etc/rancher/k3s/registries.yaml@server:*"),
        ]);
    }

    if let Some(path) = certs_d {
        cmd.args([
            "--volume",
            &format!("{path}:/var/lib/rancher/k3s/agent/etc/containerd/certs.d@server:*"),
        ]);
    }

    if let Some(path) = resolv_conf {
        cmd.args(["--volume", &format!("{path}:/etc/resolv.conf@server:*")]);
        cmd.env("K3D_FIX_DNS", "0");
    }

    if let Some(img) = image {
        cmd.args(["--image", img]);
    }
    crate::io::docker::apply_host(&mut cmd, docker_host);

    run_streaming(&mut cmd)?;

    println!(
        "{} Cluster ready (context: k3d-{name})",
        style(">>>").green()
    );
    Ok(())
}

/// # Errors
///
/// If `k3d` cannot be spawned, or it exits non-zero. Success does not mean the
/// containers are gone; [`sweep_stragglers`] is what checks that.
pub fn cluster_destroy(name: &str, docker_host: Option<&str>) -> Result<()> {
    println!("{} Destroying k3d cluster '{name}'...", style(">>>").cyan());

    let mut cmd = Command::new("k3d");
    cmd.args(["cluster", "delete", name]);

    crate::io::docker::apply_host(&mut cmd, docker_host);

    run_streaming(&mut cmd)?;

    println!("{} Cluster destroyed", style(">>>").green());
    Ok(())
}

/// # Errors
///
/// If `k3d` cannot be spawned, or it exits non-zero because there is no such
/// cluster.
pub fn cluster_stop(name: &str, docker_host: Option<&str>) -> Result<()> {
    println!("{} Stopping k3d cluster '{name}'...", style(">>>").cyan());

    let mut cmd = Command::new("k3d");
    cmd.args(["cluster", "stop", name]);

    crate::io::docker::apply_host(&mut cmd, docker_host);

    run_streaming(&mut cmd)?;

    println!("{} Cluster stopped", style(">>>").green());
    Ok(())
}

pub fn cluster_exists(name: &str, docker_host: Option<&str>) -> bool {
    let mut cmd = Command::new("k3d");
    cmd.args(["cluster", "get", name]);
    cmd.stdout(Stdio::null());
    cmd.stderr(Stdio::null());

    crate::io::docker::apply_host(&mut cmd, docker_host);

    let status = cmd.status();
    matches!(status, Ok(s) if s.success())
}

/// Where k3d should write the cluster's entry, and what it must not touch.
///
/// `--kubeconfig-merge-default` means "the default kubeconfig", which is the
/// shared file this whole design exists to stop writing. `--output` names the
/// lab's own file instead; `--update` defaults true, so it still merges rather
/// than replacing, which matters because the file holds the lab's other
/// clusters.
fn kubeconfig_merge_args(name: &str, kubeconfig: &Path) -> Vec<String> {
    vec![
        "kubeconfig".into(),
        "merge".into(),
        name.to_string(),
        "--output".into(),
        kubeconfig.display().to_string(),
        "--kubeconfig-switch-context=false".into(),
    ]
}

/// Write the cluster's entry into the lab's own kubeconfig.
///
/// # Errors
///
/// If `k3d` cannot be spawned, or it exits non-zero. The operator's default
/// kubeconfig and current-context are never touched, whether this succeeds or
/// not.
pub fn kubeconfig_merge(name: &str, docker_host: Option<&str>) -> Result<()> {
    let kubeconfig = crate::io::fs::kubeconfig_path();
    let mut cmd = Command::new("k3d");
    cmd.args(kubeconfig_merge_args(name, Path::new(&kubeconfig)));
    cmd.stdout(Stdio::null());
    crate::io::docker::apply_host(&mut cmd, docker_host);
    let status = cmd
        .status()
        .with_context(|| format!("Failed to merge kubeconfig for k3d cluster '{name}'"))?;
    if !status.success() {
        anyhow::bail!("k3d kubeconfig merge for '{name}' exited with {status}");
    }
    Ok(())
}

/// # Errors
///
/// If `k3d` cannot be spawned, or it exits non-zero because there is no such
/// cluster. The description is printed, not returned.
pub fn cluster_show(name: &str, docker_host: Option<&str>) -> Result<()> {
    let mut cmd = Command::new("k3d");
    cmd.args(["cluster", "get", name]);

    crate::io::docker::apply_host(&mut cmd, docker_host);

    run_streaming(&mut cmd)
}

/// What k3s must not install because something else does that job.
///
/// Named fields rather than four positional bools: they are all the same
/// type, so a transposition compiles and only shows up as a cluster that came
/// up with the wrong pieces running.
struct Disables {
    traefik: bool,
    service_lb: bool,
    flannel: bool,
    local_storage: bool,
}

fn k3s_server_args(
    cmd: &mut Command,
    disables: Disables,
    service_cidr: Option<&str>,
    pod_cidr: Option<&str>,
) {
    if disables.traefik {
        cmd.args(["--k3s-arg", "--disable=traefik@server:*"]);
    }
    if disables.service_lb {
        cmd.args(["--k3s-arg", "--disable=servicelb@server:*"]);
    }
    if disables.local_storage {
        cmd.args(["--k3s-arg", "--disable=local-storage@server:*"]);
    }
    if disables.flannel {
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

pub fn list_cluster_names(docker_host: Option<&str>) -> Vec<String> {
    let mut cmd = Command::new("k3d");
    cmd.args(["cluster", "list", "-o", "json"]);
    cmd.stderr(Stdio::null());
    crate::io::docker::apply_host(&mut cmd, docker_host);

    let Ok(out) = cmd.output() else {
        return Vec::new();
    };
    if !out.status.success() {
        return Vec::new();
    }

    serde_json::from_slice::<serde_json::Value>(&out.stdout)
        .ok()
        .and_then(|v| {
            v.as_array().map(|clusters| {
                clusters
                    .iter()
                    .filter_map(|c| c["name"].as_str().map(String::from))
                    .collect()
            })
        })
        .unwrap_or_default()
}

/// Grow a cluster by `count` agent nodes.
///
/// k3d adds a node to a running cluster without disturbing what is on the
/// others, which is why this is the one shape change `lab up` makes in place.
/// Names carry a suffix so a later add does not collide with an earlier one.
///
/// # Errors
///
/// If `k3d` cannot be spawned, or a node fails to join. Nodes are added one at
/// a time, so a failure partway through leaves the earlier ones in place.
pub fn add_agents(
    cluster: &str,
    count: u32,
    existing: usize,
    docker_host: Option<&str>,
) -> Result<()> {
    for i in 0..count {
        let node = format!("cata-agent-{}", existing + i as usize);
        println!(
            "{} Adding worker '{node}' to '{cluster}'...",
            style(">>>").cyan()
        );

        let mut cmd = Command::new("k3d");
        cmd.args([
            "node",
            "create",
            &node,
            "--cluster",
            cluster,
            "--role",
            "agent",
            "--wait",
        ]);
        crate::io::docker::apply_host(&mut cmd, docker_host);
        run_streaming(&mut cmd)?;
    }
    Ok(())
}

/// Grow a cluster by `count` control plane nodes.
///
/// # Errors
///
/// If `k3d` cannot be spawned, or a node fails to join. Nodes are added one at
/// a time, so a failure partway through leaves the earlier ones in place.
pub fn add_servers(
    cluster: &str,
    count: u32,
    existing: usize,
    docker_host: Option<&str>,
) -> Result<()> {
    for i in 0..count {
        let node = format!("cata-server-{}", existing + i as usize);
        println!(
            "{} Adding control plane node '{node}' to '{cluster}'...",
            style(">>>").cyan()
        );

        let mut cmd = Command::new("k3d");
        cmd.args([
            "node",
            "create",
            &node,
            "--cluster",
            cluster,
            "--role",
            "server",
            "--wait",
        ]);
        crate::io::docker::apply_host(&mut cmd, docker_host);
        run_streaming(&mut cmd)?;
    }
    Ok(())
}

/// The node image a cluster's declaration asks for.
///
/// `provisioner.k3d.image` wins when set, because a lab that pins an exact
/// image means it. Otherwise it is derived from the Kubernetes version the
/// same way `cluster_create` derives it.
pub fn node_image_for(spec: &crate::domain::ClusterSpec) -> String {
    spec.provisioner_config
        .k3d
        .image
        .clone()
        .unwrap_or_else(|| format!("rancher/k3s:v{}-k3s1", spec.kubernetes.version))
}

/// Wait for a replaced node to be usable again, and uncordon it.
///
/// A node that comes back from a container replacement is `SchedulingDisabled`
/// until something says otherwise, so pods stay `Pending` and a convergence
/// that stopped at "Ready" would report success over a cluster running
/// nothing.
///
/// # Errors
///
/// If `kube_context` is empty, if the node is not Ready within 300s, or if it
/// is Ready but cannot be uncordoned. The second message gives the `kubectl
/// uncordon` to run by hand, because the node is otherwise healthy and idle.
pub fn wait_node_ready(kube_context: &str, node: &str) -> Result<()> {
    let kube_context = crate::io::kube_context::require_named(kube_context)?;
    let ready = crate::io::kubectl::command()
        .args([
            "--context",
            kube_context,
            "wait",
            "--for=condition=Ready",
            &format!("node/{node}"),
            "--timeout=300s",
        ])
        .status();

    match ready {
        Ok(s) if s.success() => {}
        _ => bail!(
            "node '{node}' did not become Ready within 300s after being replaced.\n\
             Its data is on its volume and was not touched. `cata diagnose` shows \
             what the node reports."
        ),
    }

    let uncordoned = crate::io::kubectl::command()
        .args(["--context", kube_context, "uncordon", node])
        .status();

    match uncordoned {
        Ok(s) if s.success() => Ok(()),
        _ => bail!(
            "node '{node}' came back but could not be uncordoned, so nothing will \
             schedule on it. Run: kubectl --context {kube_context} uncordon {node}"
        ),
    }
}

/// Node container names k3d created for a cluster.
///
/// Read from the `k3d.cluster` docker label rather than `k3d node list`,
/// whose `clusterAssociation.cluster` is null in current k3d and made this
/// return an empty list for every cluster. `add_agents` masked that with a
/// `.max(1)` on the count; a node replacement loop found nothing to replace
/// and reported success.
pub fn node_names(cluster: &str, docker_host: Option<&str>) -> Vec<String> {
    let mut cmd = crate::io::docker::command();
    cmd.args([
        "ps",
        "-a",
        "--filter",
        &format!("label=k3d.cluster={cluster}"),
        "--format",
        "{{.Names}}",
    ]);
    crate::io::docker::apply_host(&mut cmd, docker_host);
    let Ok(out) = cmd.stdout(Stdio::piped()).stderr(Stdio::null()).output() else {
        return Vec::new();
    };
    if !out.status.success() {
        return Vec::new();
    }
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .map(String::from)
        .collect()
}

/// Whether a destroyed cluster left containers behind, force-removing any it
/// finds.
///
/// `k3d cluster delete` reports success while leaving nodes running often
/// enough that this exists. Shared with `lab cleanup`, which has no spec to
/// reach it through.
pub fn sweep_stragglers(k3d_cluster_name: &str) -> bool {
    let container_prefix = format!("k3d-{k3d_cluster_name}-");
    let out = match crate::io::docker::containers_named(&container_prefix) {
        Ok(o) if o.status.success() => o,
        Ok(o) => {
            println!(
                "{} `docker ps` failed (exit {:?}): {}",
                style("ERROR").red(),
                o.status.code(),
                String::from_utf8_lossy(&o.stderr),
            );
            return false;
        }
        Err(e) => {
            println!(
                "{} could not run `docker ps` to verify destroy: {e}",
                style("ERROR").red(),
            );
            return false;
        }
    };

    let stragglers: Vec<&str> = std::str::from_utf8(&out.stdout)
        .unwrap_or("")
        .lines()
        .filter(|l| !l.is_empty())
        .collect();
    if stragglers.is_empty() {
        return true;
    }
    println!(
        "{} '{}' left {} container(s) behind: {}",
        style("ERROR").red(),
        k3d_cluster_name,
        stragglers.len(),
        stragglers.join(", "),
    );
    for c in &stragglers {
        println!("{} docker rm -f {c}", style(">>>").yellow());
        crate::io::docker::force_remove_container(c);
    }
    false
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    /// `--kubeconfig-merge-default` names the shared file this design exists
    /// to stop writing, so its absence is the assertion that matters.
    #[test]
    fn the_merge_targets_the_labs_own_file() {
        let a = super::kubeconfig_merge_args("c", Path::new("/s/kube/config"));
        assert!(a.contains(&"--output".to_string()));
        assert!(a.contains(&"/s/kube/config".to_string()));
        assert!(!a.iter().any(|x| x == "--kubeconfig-merge-default"));
        assert!(a.contains(&"--kubeconfig-switch-context=false".to_string()));
    }
}

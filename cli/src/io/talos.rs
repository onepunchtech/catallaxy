//! Talos in Docker.
//!
//! Where k3d takes flags and bind mounts, Talos takes machine config patches:
//! registry mirrors, CA trust, nameservers, API server arguments and the CNI
//! choice are all machine config. The docker provisioner's whole flag set is
//! config-patch, cpus, memory, exposed-ports, host-ip, image,
//! kubernetes-version, mount, subnet and workers.
//!
//! Two consequences that shaped this, both found by running it rather than
//! reading about it. There is no flag for the control plane count, so Talos in
//! Docker builds exactly one and a lab declaring more is refused in the module
//! rather than silently given one. And Talos creates its own network rather
//! than joining the lab's, so nodes reach the lab's services through that
//! network's gateway, which is the docker host.

use std::path::Path;
use std::process::Command;

use anyhow::Result;
use console::style;

use crate::domain::cluster::TalosConfig;
use crate::io::process::{run_capture, run_streaming};

pub struct ClusterCreate<'a> {
    pub name: &'a str,
    pub workers: u32,
    pub talos: &'a TalosConfig,
    pub docker_host: Option<&'a str>,
}

/// talosctl, which keeps two pieces of state this cannot move.
///
/// `~/.talos/config` gets the cluster's client context, and
/// `~/.talos/clusters/<name>` its provisioner state. `cluster create` takes
/// neither `--talosconfig` nor an env override for the first, and pointing
/// `TALOSCONFIG` at a per-lab file was tried and does nothing: it wrote the
/// shared file anyway.
///
/// It is survivable because both are keyed on the cluster name, which already
/// carries the lab's context prefix, so two labs do not collide on a name.
/// What is not handled is two labs writing `~/.talos/config` at the same
/// instant, which is the same unsynchronised read-modify-write the kubeconfig
/// had, one layer down and out of reach.
fn talosctl() -> Command {
    Command::new("talosctl")
}

/// # Errors
///
/// If `talosctl` cannot be spawned, or exits non-zero, or if it exits zero
/// having written no context for the cluster into the lab's kubeconfig. The
/// last is checked rather than assumed: every later step addresses the cluster
/// by that context, so a missing one would send them at whatever else is
/// there.
pub fn cluster_create(opts: ClusterCreate<'_>) -> Result<()> {
    let ClusterCreate {
        name,
        workers,
        talos,
        docker_host,
    } = opts;

    println!("{} Creating Talos cluster '{name}'...", style(">>>").cyan());

    let mut cmd = talosctl();
    cmd.args(create_args(name, workers, talos));

    crate::io::docker::apply_host(&mut cmd, docker_host);

    clear_stale_state(name, docker_host);
    clear_kubeconfig_entries(name);

    run_streaming(&mut cmd)?;

    attach_to_cluster_network(name, &talos.reachable_from, docker_host);

    let context = context_name(name);
    if !kube_context_exists(&context) {
        anyhow::bail!(
            "talosctl created the cluster but wrote no '{context}' context into \
             the lab's kubeconfig, so every later step would address a cluster \
             this run did not build. The lab's kubeconfig is {}.",
            crate::io::fs::kubeconfig_path()
        );
    }

    println!(
        "{} Cluster created (context: {context})",
        style(">>>").green()
    );
    Ok(())
}

/// Attaches the lab's containers to this cluster's network.
///
/// talosctl will not join an existing network, so the lab's containers come to
/// the cluster rather than the other way round. Moving the nodes onto the lab
/// bridge looks equivalent and is not: kube-proxy in nftables mode serves a
/// NodePort only on the addresses it knew about at startup, so an interface
/// added afterwards refuses every connection.
///
/// Best effort per container: already-connected exits non-zero and is the
/// state being aimed at.
fn attach_to_cluster_network(name: &str, containers: &[String], docker_host: Option<&str>) {
    for container in containers.iter().filter(|c| !c.is_empty()) {
        let mut cmd = crate::io::docker::command();
        cmd.args(["network", "connect", name, container]);
        crate::io::docker::apply_host(&mut cmd, docker_host);
        let _ = run_capture(&mut cmd);
    }
}

/// The context the lab addresses this cluster by, which is what
/// `cluster.ref.kubeContext` is set to in `modules/lab/provisioners/talos.nix`.
pub fn context_name(name: &str) -> String {
    format!("admin@{name}")
}

/// Remove the provisioner state talosctl keeps for a cluster that is gone.
///
/// `talosctl cluster create` refuses outright when
/// `~/.talos/clusters/<name>` exists, and `cluster_exists` deliberately asks
/// docker instead, because the state directory ignores DOCKER_HOST and lied
/// under Colima. So the two disagree: with the containers removed by anything
/// other than `talosctl cluster destroy`, cata sees no cluster, skips the
/// destroy, and the next create fails on state describing a cluster that does
/// not exist.
///
/// Only when there are no node containers. With containers present the state
/// is real and removing it would orphan them.
fn clear_stale_state(name: &str, docker_host: Option<&str>) {
    if !node_names(name, docker_host).is_empty() {
        return;
    }
    let Ok(home) = std::env::var("HOME") else {
        return;
    };
    let state = Path::new(&home).join(".talos/clusters").join(name);
    if state.is_dir() {
        let _ = std::fs::remove_dir_all(&state);
    }
}

/// Drop this cluster's entries from the lab's kubeconfig before rebuilding it.
///
/// `talosctl cluster create` merges its own entry and renames on a name it
/// already holds, so a rebuilt cluster arrives as `admin@<name>-1` and the
/// lab, which addresses the unsuffixed name, is left pointing at the cluster
/// that is gone. Run enough times and the file accumulates one entry per run.
///
/// Asking for the entry afterwards with `talosctl kubeconfig --force` fixes
/// the name and gets the server wrong: it writes the node's own address,
/// `10.6.0.2:6443`, where `cluster create` writes the host-mapped
/// `127.0.0.1:<port>`. The node address is reachable here but is not loopback,
/// so it is not exempt from the lab's proxy, and every call to it was tunnelled
/// and refused. Clearing first and letting talosctl write the entry it meant
/// to is the version with no second address in it.
fn clear_kubeconfig_entries(name: &str) {
    let context = context_name(name);
    let removals = [
        ["config", "delete-context", context.as_str()],
        ["config", "delete-cluster", name],
        ["config", "delete-user", context.as_str()],
    ];

    for args in removals {
        let _ = run_capture(crate::io::kubectl::command().args(args));
    }
}

fn kube_context_exists(context: &str) -> bool {
    run_capture(crate::io::kubectl::command().args(["config", "get-contexts", "-o", "name"]))
        .map(|out| out.lines().any(|line| line.trim() == context))
        .unwrap_or(false)
}

/// Split out from running it so the translation is testable without talosctl,
/// which is where the mistakes are: a dropped patch is a cluster with no
/// registry mirror and no CNI, and it starts fine.
fn create_args(name: &str, workers: u32, talos: &TalosConfig) -> Vec<String> {
    let mut args: Vec<String> = ["cluster", "create", "docker"]
        .iter()
        .map(|s| s.to_string())
        .collect();

    args.extend(["--name".into(), name.to_string()]);
    args.extend(["--workers".into(), workers.to_string()]);

    if let Some(version) = &talos.kubernetes_version {
        args.extend(["--kubernetes-version".into(), version.clone()]);
    }
    if let Some(image) = &talos.image {
        args.extend(["--image".into(), image.clone()]);
    }
    if !talos.subnet.is_empty() {
        args.extend(["--subnet".into(), talos.subnet.clone()]);
    }
    if !talos.memory.is_empty() {
        args.extend(["--memory-controlplanes".into(), talos.memory.clone()]);
        args.extend(["--memory-workers".into(), talos.memory.clone()]);
    }
    if !talos.cpus.is_empty() {
        args.extend(["--cpus-controlplanes".into(), talos.cpus.clone()]);
        args.extend(["--cpus-workers".into(), talos.cpus.clone()]);
    }
    if !talos.exposed_ports.is_empty() {
        args.extend(["--exposed-ports".into(), talos.exposed_ports.join(",")]);
    }
    for mount in &talos.mounts {
        args.extend(["--mount".into(), mount.clone()]);
    }
    for patch in &talos.config_patches {
        args.extend(["--config-patch".into(), patch.clone()]);
    }

    args
}

/// Take the lab's own containers back off the cluster's network.
///
/// The counterpart to `attach_to_cluster_network`. talosctl removes the
/// network it made as part of destroying the cluster, and docker refuses to
/// remove a network that still has an endpoint on it, so leaving the lab's
/// proxy attached failed the teardown with "has active endpoints" and left the
/// cluster half torn down.
///
/// Only containers that are not this cluster's nodes: talosctl removes those
/// itself, and disconnecting them first would be work for nothing.
fn detach_from_cluster_network(name: &str, docker_host: Option<&str>) {
    let nodes = node_names(name, docker_host);

    let mut inspect = crate::io::docker::command();
    inspect.args([
        "network",
        "inspect",
        name,
        "--format",
        "{{range .Containers}}{{.Name}}\n{{end}}",
    ]);
    crate::io::docker::apply_host(&mut inspect, docker_host);
    let Ok(out) = run_capture(&mut inspect) else {
        return;
    };

    for attached in out.lines().map(str::trim).filter(|l| !l.is_empty()) {
        if nodes.iter().any(|n| n == attached) {
            continue;
        }
        let mut cmd = crate::io::docker::command();
        cmd.args(["network", "disconnect", "-f", name, attached]);
        crate::io::docker::apply_host(&mut cmd, docker_host);
        let _ = run_capture(&mut cmd);
    }
}

/// # Errors
///
/// If `talosctl` cannot be spawned, or exits non-zero. The lab's containers
/// are taken off the cluster's network first, best effort, so that step does
/// not fail the destroy.
pub fn cluster_destroy(name: &str, docker_host: Option<&str>) -> Result<()> {
    println!(
        "{} Destroying Talos cluster '{name}'...",
        style(">>>").cyan()
    );

    detach_from_cluster_network(name, docker_host);

    let mut cmd = talosctl();
    cmd.args(["cluster", "destroy", "--name", name]);

    crate::io::docker::apply_host(&mut cmd, docker_host);

    run_streaming(&mut cmd)?;

    println!("{} Cluster destroyed", style(">>>").green());
    Ok(())
}

/// Whether the cluster's nodes are actually here.
///
/// This used to test for `~/.talos/clusters/<name>/state.yaml`, which asks the
/// wrong machine: it ignored DOCKER_HOST, so under Colima a host-side file
/// decided whether containers existed inside the VM. A stale file reported a
/// destroyed cluster as present, and a cluster created from another HOME
/// reported absent and then collided on creation. With HOME unset it looked
/// under /tmp, which is a silent wrong answer rather than an error.
pub fn cluster_exists(name: &str, docker_host: Option<&str>) -> bool {
    !node_names(name, docker_host).is_empty()
}

/// Node containers talosctl created for this cluster.
pub fn node_names(name: &str, docker_host: Option<&str>) -> Vec<String> {
    let mut cmd = crate::io::docker::command();
    cmd.args([
        "ps",
        "-a",
        "--filter",
        &format!("name=^{name}-(controlplane|worker)-"),
        "--format",
        "{{.Names}}",
    ]);
    crate::io::docker::apply_host(&mut cmd, docker_host);
    let Ok(out) = cmd
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .output()
    else {
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

/// # Errors
///
/// If `talosctl` cannot be spawned, or exits non-zero because there is no such
/// cluster. The description is printed, not returned.
pub fn cluster_show(name: &str, docker_host: Option<&str>) -> Result<()> {
    let mut cmd = talosctl();
    cmd.args(["cluster", "show", "--name", name]);

    crate::io::docker::apply_host(&mut cmd, docker_host);

    run_streaming(&mut cmd)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn talos() -> TalosConfig {
        TalosConfig {
            cluster_name: "minimal-app".into(),
            image: Some("ghcr.io/siderolabs/talos:v1.12.6".into()),
            kubernetes_version: Some("1.32.5".into()),
            subnet: "10.6.0.0/24".into(),
            exposed_ports: vec!["8080:80/tcp".into()],
            mounts: vec!["type=bind,source=/h,destination=/c".into()],
            memory: "2.5GiB".into(),
            cpus: "2.0".into(),
            config_patches: vec![r#"{"cluster":{"inlineManifests":[]}}"#.into()],
            reachable_from: vec!["catallaxy-minimal.talos-ingress".into()],
        }
    }

    fn args() -> Vec<String> {
        create_args("minimal-app", 1, &talos())
    }

    fn value_after(args: &[String], flag: &str) -> Option<String> {
        args.iter()
            .position(|a| a == flag)
            .and_then(|i| args.get(i + 1).cloned())
    }

    #[test]
    fn the_docker_provisioner_is_a_subcommand_not_a_flag() {
        assert_eq!(&args()[..3], &["cluster", "create", "docker"]);
    }

    // Talos separates the operating system from Kubernetes, which k3d does
    // not: there a single node image decides both. Passing only one of these
    // silently takes talosctl's default for the other.
    #[test]
    fn the_talos_image_and_the_kubernetes_version_are_both_passed() {
        let a = args();
        assert_eq!(
            value_after(&a, "--image").as_deref(),
            Some("ghcr.io/siderolabs/talos:v1.12.6")
        );
        assert_eq!(
            value_after(&a, "--kubernetes-version").as_deref(),
            Some("1.32.5")
        );
    }

    // Every patch is a whole area of configuration: a dropped one is a cluster
    // with no registry mirror or no CNI, and it starts fine either way.
    #[test]
    fn every_config_patch_reaches_the_command() {
        let mut cfg = talos();
        cfg.config_patches = vec!["a".into(), "b".into()];
        let a = create_args("c", 1, &cfg);
        let patches: Vec<&String> = a
            .iter()
            .enumerate()
            .filter(|(i, _)| i > &0 && a[i - 1] == "--config-patch")
            .map(|(_, v)| v)
            .collect();
        assert_eq!(patches, vec!["a", "b"]);
    }

    #[test]
    fn exposed_ports_are_one_comma_separated_flag_and_mounts_are_repeated() {
        let mut cfg = talos();
        cfg.exposed_ports = vec!["80:80/tcp".into(), "443:443/tcp".into()];
        cfg.mounts = vec!["m1".into(), "m2".into()];
        let a = create_args("c", 1, &cfg);
        assert_eq!(
            value_after(&a, "--exposed-ports").as_deref(),
            Some("80:80/tcp,443:443/tcp")
        );
        assert_eq!(a.iter().filter(|x| *x == "--mount").count(), 2);
    }

    #[test]
    fn the_subnet_is_passed_because_talos_makes_its_own_network() {
        assert_eq!(
            value_after(&args(), "--subnet").as_deref(),
            Some("10.6.0.0/24")
        );
    }

    // Node resources are per-role flags, and a lab that sizes its nodes means
    // both roles.
    #[test]
    fn memory_and_cpu_apply_to_both_roles() {
        let a = args();
        assert_eq!(
            value_after(&a, "--memory-controlplanes").as_deref(),
            Some("2.5GiB")
        );
        assert_eq!(
            value_after(&a, "--memory-workers").as_deref(),
            Some("2.5GiB")
        );
        assert_eq!(value_after(&a, "--cpus-workers").as_deref(), Some("2.0"));
    }

    // There is no --controlplanes flag for the docker provisioner. Emitting
    // one would fail at runtime; the count is refused in the module instead.
    #[test]
    fn no_control_plane_count_is_ever_passed() {
        assert!(!args().iter().any(|a| a.contains("controlplanes")
            && a != "--memory-controlplanes"
            && a != "--cpus-controlplanes"));
    }

    #[test]
    fn an_unset_image_takes_talosctls_own_default() {
        let mut cfg = talos();
        cfg.image = None;
        let a = create_args("c", 1, &cfg);
        assert!(!a.iter().any(|x| x == "--image"));
    }

    /// The lab sets `cluster.ref.kubeContext` to this string in
    /// `modules/lab/provisioners/talos.nix`, and every step after cluster
    /// creation addresses the cluster through it. Drifting one without the
    /// other deploys to whatever else answers.
    #[test]
    fn the_context_is_the_one_the_lab_module_declares() {
        assert_eq!(context_name("minimal-talos-app"), "admin@minimal-talos-app");
    }
}

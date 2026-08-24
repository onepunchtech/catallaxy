use std::collections::HashMap;
use std::process::{Command, Stdio};

use anyhow::Result;

use crate::io::process::run_streaming;

/// A docker invocation.
///
/// Every docker the CLI spawns goes through here, so that what a docker
/// subprocess inherits is one decision rather than thirty. It deliberately
/// adds nothing today: routing docker through `io::process::prepare_env`
/// would hand it the lab's proxy variables, and whether an image pull should
/// traverse a lab's ingress is a question worth asking on purpose rather than
/// inheriting from a refactor.
#[must_use]
pub fn command() -> Command {
    Command::new("docker")
}

/// Points a command at a particular docker daemon.
///
/// `k3d`, `talosctl` and `docker` all read `DOCKER_HOST`, and all three had
/// their own copy of this three-line conditional.
pub fn apply_host(cmd: &mut Command, docker_host: Option<&str>) {
    if let Some(host) = docker_host {
        cmd.env("DOCKER_HOST", host);
    }
}

pub fn daemon_reachable() -> bool {
    command()
        .args(["info", "--format", "{{.ServerVersion}}"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

pub fn container_running(name: &str) -> bool {
    let output = command()
        .args(["inspect", "-f", "{{.State.Running}}", name])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output();

    match output {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim() == "true",
        _ => false,
    }
}

pub fn container_exists(name: &str) -> bool {
    command()
        .args(["inspect", name])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

pub fn get_container_ip(container: &str) -> Option<String> {
    let output = command()
        .args(["inspect", "-f", "{{.NetworkSettings.IPAddress}}", container])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok()?;

    if output.status.success() {
        let ip = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !ip.is_empty() {
            return Some(ip);
        }
    }
    None
}

pub struct RunContainer<'a> {
    pub name: &'a str,
    pub image: &'a str,
    pub ports: &'a [&'a str],
    pub volume_mounts: &'a [(&'a str, &'a str)],
    pub link: Option<&'a str>,
    pub networks: &'a [&'a str],
    pub dns_ips: &'a [String],
    pub command: &'a [&'a str],
    pub network_mode: Option<&'a str>,
    pub cap_add: &'a [&'a str],
    pub network_ips: &'a HashMap<String, String>,
    /// Who this container belongs to. Without it nothing can find a lab that
    /// was left running, or remove one the flake no longer defines.
    pub labels: &'a [(String, String)],
}

/// `docker run` arguments for a set of labels.
///
/// Split out so the pairing is testable without spawning docker.
pub fn label_args(labels: &[(String, String)]) -> Vec<String> {
    labels
        .iter()
        .flat_map(|(k, v)| ["--label".to_string(), format!("{k}={v}")])
        .collect()
}

/// Start a container, replacing a stopped one of the same name.
///
/// # Errors
///
/// If `docker run` cannot be spawned, or exits non-zero. Attaching the extra
/// networks afterwards is best effort, so a container can be returned as
/// started while reachable on fewer networks than were asked for.
pub fn run_container_extended(opts: RunContainer<'_>) -> Result<()> {
    let RunContainer {
        name,
        image,
        ports,
        volume_mounts,
        link,
        networks,
        dns_ips,
        command: container_command,
        network_mode,
        cap_add,
        network_ips,
        labels,
    } = opts;
    if container_exists(name) && !container_running(name) {
        let _ = command()
            .args(["rm", name])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }

    let mut cmd = command();
    cmd.args(["run", "-d", "--name", name, "--restart", "unless-stopped"]);
    for arg in label_args(labels) {
        cmd.arg(arg);
    }

    if let Some(mode) = network_mode {
        cmd.args(["--network", mode]);
    } else if let Some(first_net) = networks.first() {
        cmd.args(["--network", first_net]);
    }

    for cap in cap_add {
        cmd.args(["--cap-add", cap]);
    }

    for port in ports {
        cmd.args(["-p", port]);
    }

    for (host_path, container_path) in volume_mounts {
        cmd.args(["-v", &format!("{host_path}:{container_path}")]);
    }

    for dns_ip in dns_ips {
        cmd.args(["--dns", dns_ip]);
    }

    if let Some(link_container) = link {
        cmd.args(["--link", link_container]);
    }

    cmd.arg(image);
    cmd.args(container_command);
    run_streaming(&mut cmd)?;

    for network in networks {
        if let Some(ip) = network_ips.get(*network) {
            let _ = command()
                .args(["network", "connect", "--ip", ip, network, name])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
        } else {
            let _ = command()
                .args(["network", "connect", network, name])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
        }
    }

    Ok(())
}

/// Stop a container and remove it, skipping whichever step is already done.
///
/// # Errors
///
/// If `docker` cannot be spawned, or the stop or the remove exits non-zero. A
/// container that is not there is success.
pub fn stop_container(name: &str) -> Result<()> {
    if container_running(name) {
        let mut cmd = command();
        cmd.args(["stop", name]);
        run_streaming(&mut cmd)?;
    }

    if container_exists(name) {
        let mut cmd = command();
        cmd.args(["rm", name]);
        run_streaming(&mut cmd)?;
    }

    Ok(())
}

pub fn network_subnets() -> Vec<String> {
    let names = match command()
        .args(["network", "ls", "--format", "{{.Name}}"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
    {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).to_string(),
        _ => return Vec::new(),
    };

    names
        .lines()
        .map(str::trim)
        .filter(|n| !n.is_empty())
        .flat_map(subnets_of)
        .collect()
}

fn subnets_of(network: &str) -> Vec<String> {
    let out = command()
        .args([
            "network",
            "inspect",
            network,
            "-f",
            "{{range .IPAM.Config}}{{.Subnet}}\n{{end}}",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output();

    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout)
            .lines()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(String::from)
            .collect(),
        _ => Vec::new(),
    }
}

pub fn network_subnets_of(network: &str) -> Vec<String> {
    subnets_of(network)
}

pub fn first_network_ip(container: &str) -> Option<String> {
    let output = command()
        .args([
            "inspect",
            "--format",
            "{{range .NetworkSettings.Networks}}{{.IPAddress}}\n{{end}}",
            container,
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .map(str::to_string)
}

/// Containers publishing this port on an address another lab could want.
///
/// `--filter publish=<port>` matches whatever the address, and the ingress
/// publishes 80 and 443 on its own lab's bridge gateway so that pods reach it
/// there. Counting those said one lab's `172.25.0.1:80` was in the way of
/// another's `127.0.0.1:80` and refused to start it, which is not how docker
/// binds anything.
///
/// `{{.Ports}}` renders as `172.25.0.1:80->80/tcp, 127.0.0.1:8080->80/tcp`, so
/// the address is right there next to the port.
pub fn containers_publishing(port: u16) -> Vec<String> {
    let out = command()
        .args([
            "ps",
            "--filter",
            &format!("publish={port}"),
            "--format",
            "{{.Names}}\t{{.Ports}}",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output();

    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout)
            .lines()
            .filter_map(|line| line.split_once('\t'))
            .filter(|(_, ports)| publishes_shared(ports, port))
            .map(|(name, _)| name.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect(),
        _ => Vec::new(),
    }
}

/// Whether any of these mappings puts `port` somewhere two labs could collide.
///
/// An entry with no address is every interface. An explicit address collides
/// only with itself, and each lab's gateway address is its own.
pub fn publishes_shared(ports: &str, port: u16) -> bool {
    ports.split(',').map(str::trim).any(|entry| {
        let Some((host_side, _)) = entry.split_once("->") else {
            return false;
        };
        let (addr, host_port) = match host_side.rsplit_once(':') {
            Some((a, p)) => (Some(a), p),
            None => (None, host_side),
        };
        if host_port.parse::<u16>() != Ok(port) {
            return false;
        }
        crate::domain::port_mapping::address_is_shared(addr)
    })
}

pub fn network_exists(name: &str) -> bool {
    command()
        .args(["network", "inspect", name])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// # Errors
///
/// Only if `docker` cannot be spawned. A subnet that overlaps an existing
/// network, or a name already taken, is a non-zero status in the returned
/// `Output` with docker's reason in its `stderr`.
pub fn create_network(
    name: &str,
    subnet: &str,
    gateway: &str,
) -> std::io::Result<std::process::Output> {
    command()
        .args([
            "network",
            "create",
            "-d",
            "bridge",
            "--subnet",
            subnet,
            "--gateway",
            gateway,
            name,
        ])
        .output()
}

pub fn remove_network(name: &str) {
    let _ = command()
        .args(["network", "rm", name])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

/// Names of containers, running or not, whose name matches `prefix`.
///
/// # Errors
///
/// Only if `docker` cannot be spawned. An unreachable daemon is a non-zero
/// status in the returned `Output`, which callers have to check: an empty
/// `stdout` would otherwise read as "no such containers".
pub fn containers_named(prefix: &str) -> std::io::Result<std::process::Output> {
    command()
        .args([
            "ps",
            "-a",
            "--format",
            "{{.Names}}",
            "--filter",
            &format!("name={prefix}"),
        ])
        .output()
}

pub fn force_remove_container(name: &str) {
    let _ = command().args(["rm", "-f", name]).status();
}

/// A `docker inspect` field of a running container, or None if it cannot be
/// read. A container that is gone and one whose field is empty are different
/// answers.
pub fn inspect_field(name: &str, template: &str) -> Option<String> {
    let output = command()
        .args(["inspect", "-f", template, name])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// A label on a running container, or None if it is absent or unreadable.
pub fn container_label(name: &str, key: &str) -> Option<String> {
    let raw = inspect_field(name, &format!("{{{{index .Config.Labels \"{key}\"}}}}"))?;
    (!raw.is_empty() && raw != "<no value>").then_some(raw)
}

/// How many times docker has restarted this container.
///
/// A service that crash-loops is `Running` between attempts, so asking whether
/// it is running says yes to a container that has never served a request. The
/// ingress spent a whole e2e run failing to read its own certificate while
/// every step reported it as started.
pub fn container_restart_count(name: &str) -> Option<u32> {
    inspect_field(name, "{{.RestartCount}}")?.parse().ok()
}

/// Whether docker is waiting to restart this container right now.
///
/// Unlike the restart count, this says nothing about history, so it is the
/// question to ask about a container this run did not start: one restarted a
/// month ago when the daemon came back is healthy, one restarting now is not.
pub fn container_restarting(name: &str) -> bool {
    inspect_field(name, "{{.State.Restarting}}").is_some_and(|v| v == "true")
}

/// The tail of a container's log, for saying why it did not start.
pub fn container_logs(name: &str, lines: u32) -> Option<String> {
    let output = command()
        .args(["logs", "--tail", &lines.to_string(), name])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .ok()?;
    let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
    text.push_str(&String::from_utf8_lossy(&output.stderr));
    let trimmed = text.trim().to_string();
    (!trimmed.is_empty()).then_some(trimmed)
}

pub fn container_image(name: &str) -> Option<String> {
    inspect_field(name, "{{.Config.Image}}")
}

/// Published ports as `host:container`, sorted so the order docker reports
/// them in is not mistaken for a change.
pub fn container_ports(name: &str) -> Option<Vec<String>> {
    // Including the bind address, because the ingress publishes on loopback
    // and on the lab's own gateway and those are different bindings of the
    // same container port. Rendering only the port made both read as `80:80`,
    // which never matched what was declared, so every `lab up` saw drift that
    // was not there and rebuilt the container.
    let raw = inspect_field(
        name,
        "{{range $p, $bindings := .HostConfig.PortBindings}}\
         {{range $bindings}}{{if .HostIp}}{{.HostIp}}:{{end}}{{.HostPort}}:{{$p}} {{end}}{{end}}",
    )?;
    let mut ports: Vec<String> = raw
        .split_whitespace()
        .map(|p| p.trim_end_matches("/tcp").to_string())
        .collect();
    ports.sort();
    Some(ports)
}

#[cfg(test)]
mod label_tests {
    use super::*;
    use crate::domain::provenance::Provenance;

    #[test]
    fn each_label_becomes_a_flag_and_a_pair() {
        let args = label_args(&[("a".to_string(), "1".to_string())]);
        assert_eq!(args, vec!["--label".to_string(), "a=1".to_string()]);
    }

    #[test]
    fn no_labels_add_no_arguments() {
        assert!(label_args(&[]).is_empty());
    }

    #[test]
    fn a_lab_containers_provenance_reaches_the_command_line() {
        let args = label_args(&Provenance::new("home-lab", "/src#home-lab").labels("ingress"));
        assert!(
            args.contains(&"catallaxy.io/lab=home-lab".to_string()),
            "{args:?}"
        );
        assert!(
            args.contains(&"catallaxy.io/flake=/src#home-lab".to_string()),
            "{args:?}"
        );
        assert!(
            args.contains(&"catallaxy.io/managed-by=catallaxy".to_string()),
            "{args:?}"
        );
    }

    #[test]
    fn a_value_containing_an_equals_is_not_split() {
        let args = label_args(&[("k".to_string(), "a=b".to_string())]);
        assert_eq!(args[1], "k=a=b");
    }
}

#[cfg(test)]
mod publish_tests {
    /// The ingress publishes on its own lab's gateway as well as loopback, and
    /// gateway addresses are unique per lab, so only the loopback half is
    /// contended.
    #[test]
    fn only_shared_addresses_count_as_publishing() {
        let both = "172.25.0.1:80->80/tcp, 127.0.0.1:8080->80/tcp";
        assert!(!super::publishes_shared(both, 80));
        assert!(super::publishes_shared(both, 8080));

        assert!(super::publishes_shared("0.0.0.0:80->80/tcp", 80));
        assert!(!super::publishes_shared("80/tcp", 80));
        assert!(!super::publishes_shared("172.20.0.1:443->443/tcp", 443));
    }
}

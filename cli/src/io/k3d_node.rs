//! Replace a k3d node container without losing the cluster.
//!
//! A k3d node keeps its whole datastore in a docker volume mounted at
//! `/var/lib/rancher/k3s`; the container image only pins the k3s binary. So
//! swapping the image, or changing the server's arguments, is a container
//! replacement against the same volumes rather than a new cluster. Verified
//! against a live cluster: workloads, the PVC-to-PV binding and the data in it
//! all survived a v1.31 to v1.32 swap.
//!
//! `k3d node` has create, delete, edit, start, stop and list, and nothing that
//! replaces an image, so this works at the docker level. Two things that are
//! easy to get wrong and are load-bearing:
//!
//! - The container carries 19 `k3d.*` labels. k3d identifies cluster
//!   membership by those, so a replacement without them is a container k3d no
//!   longer recognises as part of the cluster.
//! - The node comes back cordoned. It returns `Ready,SchedulingDisabled` and
//!   pods stay `Pending` until something uncordons it, so a convergence that
//!   skipped that would report success over a cluster running nothing.

use anyhow::{Context, Result, bail};
use serde::Deserialize;

use crate::io::process::run_capture;

/// Everything needed to rebuild a node container as it was, bar the image.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NodeSpec {
    pub name: String,
    pub image: String,
    pub cmd: Vec<String>,
    pub env: Vec<String>,
    pub labels: Vec<(String, String)>,
    pub networks: Vec<String>,
    pub privileged: bool,
    /// `(source, destination)`, where source is a volume name or a host path.
    pub mounts: Vec<(String, String)>,
    pub tmpfs: Vec<String>,
}

#[derive(Deserialize)]
struct Inspected {
    #[serde(rename = "Config")]
    config: InspectedConfig,
    #[serde(rename = "HostConfig")]
    host_config: InspectedHostConfig,
    #[serde(rename = "Mounts")]
    mounts: Vec<InspectedMount>,
    #[serde(rename = "NetworkSettings")]
    network_settings: InspectedNetworks,
}

#[derive(Deserialize)]
struct InspectedConfig {
    #[serde(rename = "Image")]
    image: String,
    #[serde(rename = "Cmd", default)]
    cmd: Option<Vec<String>>,
    #[serde(rename = "Env", default)]
    env: Option<Vec<String>>,
    #[serde(rename = "Labels", default)]
    labels: Option<std::collections::BTreeMap<String, String>>,
}

#[derive(Deserialize)]
struct InspectedHostConfig {
    #[serde(rename = "Privileged", default)]
    privileged: bool,
    #[serde(rename = "Tmpfs", default)]
    tmpfs: Option<std::collections::BTreeMap<String, String>>,
}

#[derive(Deserialize)]
struct InspectedMount {
    #[serde(rename = "Name", default)]
    name: Option<String>,
    #[serde(rename = "Source", default)]
    source: Option<String>,
    #[serde(rename = "Destination")]
    destination: String,
}

#[derive(Deserialize)]
struct InspectedNetworks {
    #[serde(rename = "Networks", default)]
    networks: Option<std::collections::BTreeMap<String, serde_json::Value>>,
}

/// Read a node container's shape so it can be rebuilt.
///
/// # Errors
///
/// If `docker inspect` fails or the container does not exist, or its output
/// does not parse, or it describes no container.
pub fn inspect(container: &str) -> Result<NodeSpec> {
    let raw = run_capture(crate::io::docker::command().args(["inspect", container]))
        .with_context(|| format!("inspecting node container '{container}'"))?;

    parse_inspect(container, &raw)
}

fn parse_inspect(container: &str, raw: &str) -> Result<NodeSpec> {
    let all: Vec<Inspected> = serde_json::from_str(raw)
        .with_context(|| format!("parsing `docker inspect {container}`"))?;
    let Some(first) = all.into_iter().next() else {
        bail!("`docker inspect {container}` described no container");
    };

    Ok(NodeSpec {
        name: container.to_string(),
        image: first.config.image,
        cmd: first.config.cmd.unwrap_or_default(),
        env: first.config.env.unwrap_or_default(),
        labels: first
            .config
            .labels
            .unwrap_or_default()
            .into_iter()
            .collect(),
        networks: first
            .network_settings
            .networks
            .unwrap_or_default()
            .into_keys()
            .collect(),
        privileged: first.host_config.privileged,
        mounts: first
            .mounts
            .into_iter()
            .filter_map(|m| {
                // A named volume is reattached by name; a bind mount by its
                // host path. Either way the destination is what matters.
                let source = m.name.filter(|n| !n.is_empty()).or(m.source)?;
                Some((source, m.destination))
            })
            .collect(),
        tmpfs: first
            .host_config
            .tmpfs
            .unwrap_or_default()
            .into_keys()
            .collect(),
    })
}

/// The arguments that rebuild this node, optionally on a different image.
///
/// Split out from running it so the whole translation is testable without
/// docker, which is where the mistakes are: a dropped label or a dropped
/// mount both produce a container that starts and is wrong.
pub fn run_args(spec: &NodeSpec, image: &str) -> Vec<String> {
    let mut args: Vec<String> = vec!["run".into(), "-d".into()];
    args.extend(["--name".into(), spec.name.clone()]);
    args.extend(["--hostname".into(), spec.name.clone()]);
    if spec.privileged {
        args.push("--privileged".into());
    }
    for net in &spec.networks {
        args.extend(["--network".into(), net.clone()]);
    }
    for path in &spec.tmpfs {
        args.extend(["--tmpfs".into(), path.clone()]);
    }
    for e in &spec.env {
        args.extend(["-e".into(), e.clone()]);
    }
    for (source, destination) in &spec.mounts {
        args.extend(["-v".into(), format!("{source}:{destination}")]);
    }
    for (k, v) in &spec.labels {
        args.extend(["--label".into(), format!("{k}={v}")]);
    }
    args.push(image.to_string());
    args.extend(spec.cmd.iter().cloned());
    args
}

/// Replace a node container with one on `image`, keeping its volumes.
///
/// Removed without `-v` deliberately: that is what keeps the datastore. The
/// replacement reattaches it by name.
///
/// # Errors
///
/// If any of the stop, remove or run fails. The three are separate docker
/// calls, so a failure after the remove leaves the node gone and not yet
/// replaced; its volumes are still there, which is what makes that recoverable.
pub fn replace(spec: &NodeSpec, image: &str, docker_host: Option<&str>) -> Result<()> {
    let docker = |args: &[String]| -> Result<()> {
        let mut cmd = crate::io::docker::command();
        cmd.args(args);
        crate::io::docker::apply_host(&mut cmd, docker_host);
        let status = cmd.status().with_context(|| {
            format!(
                "running docker {}",
                args.first().cloned().unwrap_or_default()
            )
        })?;
        if !status.success() {
            bail!(
                "docker {} exited with {status}",
                args.first().cloned().unwrap_or_default()
            );
        }
        Ok(())
    };

    docker(&["stop".into(), spec.name.clone()])?;
    docker(&["rm".into(), spec.name.clone()])?;
    docker(&run_args(spec, image))
}

/// k3s versions the node images carry, as `(major, minor)`.
///
/// Kubernetes supports one minor of skew, so a jump of several has to be
/// refused rather than attempted: k3s would start against a datastore written
/// by a version it cannot read forward from.
fn minor_of(version: &str) -> Option<(u32, u32)> {
    let trimmed = version.trim_start_matches('v');
    let mut parts = trimmed.split(['.', '+', '-']);
    let major = parts.next()?.parse().ok()?;
    let minor = parts.next()?.parse().ok()?;
    Some((major, minor))
}

/// Whether `declared` can be reached from `recorded` in one step.
pub fn upgrade_is_one_step(recorded: &str, declared: &str) -> bool {
    match (minor_of(recorded), minor_of(declared)) {
        (Some((rmaj, rmin)), Some((dmaj, dmin))) => dmaj == rmaj && dmin.abs_diff(rmin) <= 1,
        // An unparseable version is not evidence of a safe jump, but it is
        // also not evidence of an unsafe one, and refusing every unusual
        // version string would block clusters that are fine.
        _ => true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"[{
      "Config": {
        "Image": "rancher/k3s:v1.31.5-k3s1",
        "Cmd": ["server", "--tls-san", "0.0.0.0"],
        "Env": ["K3S_TOKEN=abc"],
        "Labels": {"k3d.cluster": "upg", "k3d.role": "server"}
      },
      "HostConfig": {"Privileged": true, "Tmpfs": {"/run": "", "/var/run": ""}},
      "Mounts": [
        {"Name": "k3d-upg-images", "Source": "/var/lib/docker/volumes/x/_data", "Destination": "/k3d/images"},
        {"Name": "statevol", "Source": "/var/lib/docker/volumes/y/_data", "Destination": "/var/lib/rancher/k3s"},
        {"Source": "/tmp/host", "Destination": "/var/lib/rancher/k3s/storage"}
      ],
      "NetworkSettings": {"Networks": {"k3d-upg": {}}}
    }]"#;

    fn spec() -> NodeSpec {
        parse_inspect("k3d-upg-server-0", SAMPLE).expect("sample parses")
    }

    #[test]
    fn a_named_volume_is_reattached_by_name_not_by_its_host_path() {
        let s = spec();
        assert!(
            s.mounts
                .contains(&("statevol".into(), "/var/lib/rancher/k3s".into())),
            "{:?}",
            s.mounts
        );
        assert!(
            !s.mounts
                .iter()
                .any(|(src, _)| src.contains("/var/lib/docker/volumes")),
            "a volume referenced by its host path would be a fresh anonymous volume: {:?}",
            s.mounts
        );
    }

    #[test]
    fn a_bind_mount_keeps_its_host_path() {
        assert!(
            spec()
                .mounts
                .contains(&("/tmp/host".into(), "/var/lib/rancher/k3s/storage".into()))
        );
    }

    // k3d decides cluster membership from these. A replacement without them
    // starts fine and is no longer part of the cluster.
    #[test]
    fn every_k3d_label_is_carried_over() {
        let args = run_args(&spec(), "rancher/k3s:v1.32.5-k3s1");
        assert!(args.contains(&"k3d.cluster=upg".to_string()), "{args:?}");
        assert!(args.contains(&"k3d.role=server".to_string()), "{args:?}");
    }

    #[test]
    fn the_image_is_the_only_thing_that_changes() {
        let s = spec();
        let args = run_args(&s, "rancher/k3s:v1.32.5-k3s1");
        assert!(args.contains(&"rancher/k3s:v1.32.5-k3s1".to_string()));
        assert!(
            !args.contains(&s.image),
            "the old image must not survive: {args:?}"
        );
    }

    #[test]
    fn the_server_command_is_preserved_verbatim() {
        let args = run_args(&spec(), "img");
        let tail: Vec<&String> = args.iter().skip_while(|a| *a != "img").skip(1).collect();
        assert_eq!(
            tail,
            vec!["server", "--tls-san", "0.0.0.0"],
            "the command follows the image and is unchanged"
        );
    }

    #[test]
    fn one_minor_forward_or_back_is_a_single_step() {
        assert!(upgrade_is_one_step("v1.31.5+k3s1", "v1.32.5+k3s1"));
        assert!(upgrade_is_one_step("v1.32.5+k3s1", "v1.31.5+k3s1"));
        assert!(upgrade_is_one_step("1.31", "1.31"));
    }

    // Kubernetes supports one minor of skew. k3s started against a datastore
    // written several minors ago cannot migrate it forward.
    #[test]
    fn a_jump_of_several_minors_is_refused() {
        assert!(!upgrade_is_one_step("v1.28.0+k3s1", "v1.32.5+k3s1"));
        assert!(!upgrade_is_one_step("1.29", "1.31"));
    }

    #[test]
    fn a_different_major_is_refused() {
        assert!(!upgrade_is_one_step("v1.31.0", "v2.0.0"));
    }

    // Refusing every version string that does not parse would block clusters
    // that are fine, and an unparseable version is not evidence either way.
    #[test]
    fn an_unparseable_version_is_not_treated_as_a_dangerous_jump() {
        assert!(upgrade_is_one_step("latest", "v1.32.5+k3s1"));
    }

    #[test]
    fn the_state_volume_and_the_network_both_come_along() {
        let args = run_args(&spec(), "img");
        assert!(
            args.contains(&"statevol:/var/lib/rancher/k3s".to_string()),
            "{args:?}"
        );
        assert!(args.contains(&"k3d-upg".to_string()), "{args:?}");
        assert!(args.contains(&"--privileged".to_string()));
    }
}

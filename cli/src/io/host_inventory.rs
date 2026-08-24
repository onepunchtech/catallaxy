//! Ask the machine what it is running. Decides nothing.
//!
//! Every judgement about what these facts mean lives in
//! `domain::inventory::correlate`, which is a pure function and therefore
//! testable without docker.

use std::collections::BTreeMap;
use std::process::Stdio;

use crate::domain::inventory::{ContainerFact, HostFacts};
use crate::domain::provenance;

fn docker_output(args: &[&str]) -> Option<String> {
    let out = crate::io::docker::command()
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).to_string())
}

fn lines_of(raw: Option<String>) -> Vec<String> {
    raw.map(|s| {
        s.lines()
            .map(str::trim)
            .filter(|l| !l.is_empty())
            .map(String::from)
            .collect()
    })
    .unwrap_or_default()
}

/// Container names worth inspecting: anything catallaxy labelled, plus
/// anything named like one of ours, so containers created before labels
/// existed are still found.
fn candidate_names() -> Vec<String> {
    let mut names = lines_of(docker_output(&[
        "ps",
        "-a",
        "--filter",
        &format!(
            "label={}={}",
            provenance::MANAGED_BY,
            provenance::MANAGED_BY_VALUE
        ),
        "--format",
        "{{.Names}}",
    ]));

    names.extend(lines_of(docker_output(&[
        "ps",
        "-a",
        "--filter",
        "name=catallaxy-",
        "--format",
        "{{.Names}}",
    ])));

    names.sort();
    names.dedup();
    names
}

/// Labels and state for a batch of containers.
///
/// `docker ps --format '{{.Labels}}'` comma-joins pairs and cannot be parsed
/// back, so this inspects instead, once for the whole batch.
fn inspect(names: &[String]) -> Vec<ContainerFact> {
    if names.is_empty() {
        return Vec::new();
    }

    let mut args: Vec<&str> = vec!["inspect", "--format", "{{json .}}"];
    args.extend(names.iter().map(String::as_str));

    lines_of(docker_output(&args))
        .iter()
        .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
        .map(|v| {
            let name = v["Name"]
                .as_str()
                .unwrap_or_default()
                .trim_start_matches('/')
                .to_string();
            let labels = v["Config"]["Labels"]
                .as_object()
                .map(|o| {
                    o.iter()
                        .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
                        .collect::<BTreeMap<_, _>>()
                })
                .unwrap_or_default();
            let published = v["HostConfig"]["PortBindings"]
                .as_object()
                .map(|o| {
                    o.values()
                        .filter_map(|b| b.as_array())
                        .flatten()
                        .filter_map(|b| b["HostPort"].as_str())
                        .filter_map(|p| p.parse::<u16>().ok())
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            ContainerFact {
                name,
                running: v["State"]["Running"].as_bool().unwrap_or(false),
                labels,
                published,
            }
        })
        .collect()
}

pub fn gather() -> HostFacts {
    let docker_reachable = crate::io::docker::daemon_reachable();

    if !docker_reachable {
        return HostFacts {
            docker_reachable: false,
            records: crate::host::state::list_lab_records(),
            ..Default::default()
        };
    }

    HostFacts {
        docker_reachable: true,
        containers: inspect(&candidate_names()),
        networks: lines_of(docker_output(&["network", "ls", "--format", "{{.Name}}"])),
        k3d_clusters: crate::io::k3d::list_cluster_names(None),
        records: crate::host::state::list_lab_records(),
    }
}

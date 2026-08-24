use std::process::{Command, Stdio};

use anyhow::{Context, Result, bail};

use crate::io::process::run_capture;

pub fn api_reachable(context: &str) -> bool {
    let Ok(mut cmd) = super::run::contextual(context) else {
        return false;
    };
    let output = cmd.args(["version", "--request-timeout=2s"]).output();

    matches!(output, Ok(o) if o.status.success())
}

/// Deployments whose Progressing condition says the deadline was exceeded.
///
/// # Errors
///
/// If `context` is empty, kubectl cannot be spawned, or it exits non-zero. The
/// message says nothing below reflects the cluster, because an empty list here
/// otherwise reads as a healthy one. Output that is not JSON is an empty list.
pub fn get_stuck_deployments(context: &str) -> Result<Vec<(String, String)>> {
    let output = super::run::contextual(context)?
        .args(["get", "deployments", "-A", "-o", "json"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .context("Failed to run kubectl")?;

    if !output.status.success() {
        bail!(
            "could not read deployments on '{context}': {}\n    Nothing below reflects the cluster.",
            String::from_utf8_lossy(&output.stderr).trim(),
        );
    }

    let json: serde_json::Value =
        serde_json::from_slice(&output.stdout).unwrap_or(serde_json::Value::Null);

    let mut stuck = Vec::new();
    if let Some(items) = json["items"].as_array() {
        for item in items {
            let ns = item["metadata"]["namespace"].as_str().unwrap_or("");
            let name = item["metadata"]["name"].as_str().unwrap_or("");
            if let Some(conditions) = item["status"]["conditions"].as_array() {
                let is_stuck = conditions.iter().any(|c| {
                    c["type"].as_str() == Some("Progressing")
                        && c["reason"].as_str() == Some("ProgressDeadlineExceeded")
                });
                if is_stuck {
                    stuck.push((ns.to_string(), name.to_string()));
                }
            }
        }
    }
    Ok(stuck)
}

/// # Errors
///
/// If `context` is empty, kubectl cannot be spawned, or it exits non-zero
/// because the workload is missing. kubectl's stderr is captured and dropped,
/// so the message names only the workload.
pub fn rollout_restart(context: &str, kind: &str, namespace: &str, name: &str) -> Result<()> {
    let status = super::run::contextual(context)?
        .args([
            "rollout",
            "restart",
            &format!("{kind}/{name}"),
            "-n",
            namespace,
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .status()
        .context("Failed to run kubectl rollout restart")?;

    if !status.success() {
        bail!("Failed to restart {kind}/{name} in {namespace}");
    }
    Ok(())
}

/// Pods that are neither Running with every container ready nor finished.
///
/// # Errors
///
/// If `context` is empty, kubectl cannot be spawned, or it exits non-zero, in
/// which case the message says the result does not reflect the cluster.
pub fn get_unhealthy_pods(context: &str) -> Result<Vec<serde_json::Value>> {
    let output = super::run::contextual(context)?
        .args(["get", "pods", "-A", "-o", "json"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .context("Failed to run kubectl get pods")?;

    if !output.status.success() {
        bail!(
            "could not read pods on '{context}': {}\n    Nothing below reflects the cluster.",
            String::from_utf8_lossy(&output.stderr).trim(),
        );
    }

    let json: serde_json::Value =
        serde_json::from_slice(&output.stdout).unwrap_or(serde_json::Value::Null);

    let mut unhealthy = Vec::new();
    if let Some(items) = json["items"].as_array() {
        for pod in items {
            let phase = pod["status"]["phase"].as_str().unwrap_or("");
            match phase {
                "Running" => {
                    if let Some(statuses) = pod["status"]["containerStatuses"].as_array() {
                        let any_not_ready = statuses
                            .iter()
                            .any(|cs| cs["ready"].as_bool() != Some(true));
                        if any_not_ready {
                            unhealthy.push(pod.clone());
                        }
                    }
                }
                "Succeeded" | "Completed" => {}
                _ => {
                    unhealthy.push(pod.clone());
                }
            }
        }
    }
    Ok(unhealthy)
}

/// Warning events from the last `since_minutes`, oldest first.
///
/// # Errors
///
/// If `context` is empty, kubectl cannot be spawned, or it exits non-zero. An
/// event whose timestamp does not parse is kept rather than dropped.
pub fn get_warning_events(context: &str, since_minutes: u32) -> Result<Vec<serde_json::Value>> {
    let output = super::run::contextual(context)?
        .args([
            "get",
            "events",
            "-A",
            "--field-selector",
            "type=Warning",
            "--sort-by",
            ".lastTimestamp",
            "-o",
            "json",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .context("Failed to run kubectl get events")?;

    if !output.status.success() {
        bail!(
            "could not read events on '{context}': {}\n    Nothing below reflects the cluster.",
            String::from_utf8_lossy(&output.stderr).trim(),
        );
    }

    let json: serde_json::Value =
        serde_json::from_slice(&output.stdout).unwrap_or(serde_json::Value::Null);

    let cutoff = chrono::Utc::now() - chrono::Duration::minutes(since_minutes as i64);
    let mut events = Vec::new();
    if let Some(items) = json["items"].as_array() {
        for event in items {
            let include = event["lastTimestamp"]
                .as_str()
                .and_then(|ts| chrono::DateTime::parse_from_rfc3339(ts).ok())
                .map(|t| t >= cutoff)
                .unwrap_or(true);
            if include {
                events.push(event.clone());
            }
        }
    }
    Ok(events)
}

/// # Errors
///
/// If `context` is empty, or kubectl cannot be spawned. A pod with no logs and
/// a pod that does not exist both give an empty string, because kubectl's exit
/// status is not checked here.
pub fn get_pod_logs(
    context: &str,
    namespace: &str,
    pod_name: &str,
    tail_lines: u32,
) -> Result<String> {
    let output = super::run::contextual(context)?
        .args([
            "logs",
            pod_name,
            "-n",
            namespace,
            "--all-containers",
            "--tail",
            &tail_lines.to_string(),
            "--timestamps",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .context("Failed to get pod logs")?;

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

/// # Errors
///
/// If `context` is empty, kubectl cannot be spawned, or it exits non-zero.
pub fn get_node_status(context: &str) -> Result<Vec<serde_json::Value>> {
    let output = super::run::contextual(context)?
        .args(["get", "nodes", "-o", "json"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .context("Failed to run kubectl get nodes")?;

    if !output.status.success() {
        bail!(
            "could not read nodes on '{context}': {}\n    Nothing below reflects the cluster.",
            String::from_utf8_lossy(&output.stderr).trim(),
        );
    }

    let json: serde_json::Value =
        serde_json::from_slice(&output.stdout).unwrap_or(serde_json::Value::Null);

    Ok(json["items"].as_array().cloned().unwrap_or_default())
}

/// The `cata-` apps kapp knows about, as name, description and age.
///
/// # Errors
///
/// Never. kapp being absent or unhappy is an empty list, because this is one
/// section of a status report and a missing kapp is not a reason to fail the
/// rest of it.
pub fn get_kapp_app_statuses(context: &str) -> Result<Vec<(String, String, String)>> {
    let output = Command::new("kapp")
        .args([
            "list",
            "--kubeconfig-context",
            context,
            "--namespace",
            "default",
            "--json",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output();

    match output {
        Ok(o) if o.status.success() => {
            let json: serde_json::Value = serde_json::from_slice(&o.stdout).unwrap_or_default();
            let mut apps = Vec::new();
            if let Some(tables) = json["Tables"].as_array() {
                for table in tables {
                    if let Some(rows) = table["Rows"].as_array() {
                        for row in rows {
                            let name = row["name"].as_str().unwrap_or("").to_string();
                            if name.starts_with("cata-") {
                                let status =
                                    row["description"].as_str().unwrap_or("unknown").to_string();
                                let age = row["since-deploy"].as_str().unwrap_or("").to_string();
                                apps.push((name, status, age));
                            }
                        }
                    }
                }
            }
            Ok(apps)
        }
        _ => Ok(vec![]),
    }
}

pub struct Workload {
    pub kind: String,
    pub name: String,
    pub namespace: String,
    pub ready: i64,
    pub desired: i64,
}

/// # Errors
///
/// If `context` is empty. A namespace kubectl cannot read is skipped rather
/// than fatal, so a short list means some namespaces did not answer.
pub fn get_workload_readiness(context: &str, namespaces: &[String]) -> Result<Vec<Workload>> {
    let mut out = Vec::new();
    for namespace in namespaces {
        let output = super::run::contextual(context)?
            .args([
                "-n",
                namespace,
                "get",
                "deployments,statefulsets,daemonsets",
                "-o",
                "json",
            ])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output();

        let Ok(o) = output else { continue };
        if !o.status.success() {
            continue;
        }
        let json: serde_json::Value = serde_json::from_slice(&o.stdout).unwrap_or_default();
        let Some(items) = json["items"].as_array() else {
            continue;
        };
        for item in items {
            let kind = item["kind"].as_str().unwrap_or("Workload").to_string();
            let name = item["metadata"]["name"].as_str().unwrap_or("?").to_string();
            let status = &item["status"];
            let (ready, desired) = if kind == "DaemonSet" {
                (
                    status["numberReady"].as_i64().unwrap_or(0),
                    status["desiredNumberScheduled"].as_i64().unwrap_or(0),
                )
            } else {
                (
                    status["readyReplicas"].as_i64().unwrap_or(0),
                    item["spec"]["replicas"].as_i64().unwrap_or(1),
                )
            };
            out.push(Workload {
                kind,
                name,
                namespace: namespace.clone(),
                ready,
                desired,
            });
        }
    }
    Ok(out)
}

pub fn namespace_exists(context: &str, namespace: &str) -> bool {
    let Ok(mut cmd) = super::run::contextual(context) else {
        return false;
    };
    let output = cmd
        .args(["get", "namespace", namespace])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    matches!(output, Ok(s) if s.success())
}

pub fn namespace_phase(kube_ctx: &str, namespace: &str) -> Option<String> {
    let mut get = super::run::contextual(kube_ctx).ok()?;
    get.args(["get", "ns", namespace, "-o", "jsonpath={.status.phase}"]);
    run_capture(&mut get).ok().map(|s| s.trim().to_string())
}

pub struct NodeSummary {
    pub workers: u32,
    pub kubelet_version: Option<String>,
}

pub fn node_summary(context: &str) -> Option<NodeSummary> {
    let output = super::run::contextual(context)
        .ok()?
        .args(["get", "nodes", "-o", "json"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }

    let json: serde_json::Value = serde_json::from_slice(&output.stdout).ok()?;
    let items = json["items"].as_array()?;

    let workers = items
        .iter()
        .filter(|n| {
            let labels = &n["metadata"]["labels"];
            labels
                .get("node-role.kubernetes.io/control-plane")
                .is_none()
                && labels.get("node-role.kubernetes.io/master").is_none()
        })
        .count() as u32;

    let kubelet_version = items
        .first()
        .and_then(|n| n["status"]["nodeInfo"]["kubeletVersion"].as_str())
        .map(String::from);

    Some(NodeSummary {
        workers,
        kubelet_version,
    })
}

pub fn pods_in_namespace(
    context: &str,
    namespace: &str,
    request_timeout: Option<&str>,
) -> Option<Vec<serde_json::Value>> {
    let mut cmd = super::run::contextual(context).ok()?;
    cmd.args(["get", "pods", "-n", namespace, "-o", "json"]);
    if let Some(timeout) = request_timeout {
        cmd.arg(format!("--request-timeout={timeout}"));
    }
    let output = cmd
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let json: serde_json::Value = serde_json::from_slice(&output.stdout).ok()?;
    json["items"].as_array().cloned()
}

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use anyhow::{Context, Result, bail};
use console::style;

use crate::io::process::run_capture;

pub fn delete_kubeconfig_context(context_name: &str) -> Result<()> {
    let mut cmd = Command::new("kubectl");
    cmd.args(["config", "delete-context", context_name]);
    let _ = run_capture(&mut cmd);
    Ok(())
}

pub fn delete_kubeconfig_cluster(cluster_name: &str) -> Result<()> {
    let mut cmd = Command::new("kubectl");
    cmd.args(["config", "delete-cluster", cluster_name]);
    let _ = run_capture(&mut cmd);
    Ok(())
}

pub fn delete_kubeconfig_user(user_name: &str) -> Result<()> {
    let mut cmd = Command::new("kubectl");
    cmd.args(["config", "delete-user", user_name]);
    let _ = run_capture(&mut cmd);
    Ok(())
}

pub fn api_reachable(context: &str) -> bool {
    let output = Command::new("kubectl")
        .args(["--context", context, "version", "--request-timeout=2s"])
        .output();

    matches!(output, Ok(o) if o.status.success())
}

pub fn wait_crd_established(context: &str, crd_name: &str, timeout: &str) -> Result<()> {
    use std::time::{Duration, Instant};

    let timeout_duration = parse_timeout(timeout);
    let start = Instant::now();

    loop {
        let result = Command::new("kubectl")
            .args([
                "--context",
                context,
                "wait",
                "--for=condition=Established",
                &format!("crd/{crd_name}"),
                "--timeout=10s",
            ])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output();

        match result {
            Ok(output) if output.status.success() => {
                println!("  CRD {crd_name} established");
                return Ok(());
            }
            _ => {
                if start.elapsed() > timeout_duration {
                    bail!(
                        "Timed out waiting for CRD: {crd_name} ({}s elapsed)",
                        timeout_duration.as_secs()
                    );
                }
                let elapsed = start.elapsed().as_secs();
                println!("  waiting... ({elapsed}s elapsed, CRD not yet registered by provider)");
                std::thread::sleep(Duration::from_secs(5));
            }
        }
    }
}

pub fn get_stuck_deployments(context: &str) -> Result<Vec<(String, String)>> {
    let output = Command::new("kubectl")
        .args([
            "--context",
            context,
            "get",
            "deployments",
            "-A",
            "-o",
            "json",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .context("Failed to run kubectl")?;

    if !output.status.success() {
        return Ok(vec![]);
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

pub fn rollout_restart(context: &str, kind: &str, namespace: &str, name: &str) -> Result<()> {
    let status = Command::new("kubectl")
        .args([
            "--context",
            context,
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

pub fn wait_crossplane_healthy(context: &str) -> Result<()> {
    use std::time::{Duration, Instant};
    let timeout = Duration::from_secs(300);
    let start = Instant::now();

    loop {
        let output = Command::new("kubectl")
            .args(["--context", context, "get", "providers", "-o", "json"])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output();

        if let Ok(ref o) = output
            && o.status.success()
        {
            let json: serde_json::Value = serde_json::from_slice(&o.stdout).unwrap_or_default();
            if let Some(items) = json["items"].as_array() {
                let all_healthy = !items.is_empty()
                    && items.iter().all(|p| {
                        p["status"]["conditions"]
                            .as_array()
                            .map(|conds| {
                                conds.iter().any(|c| {
                                    c["type"].as_str() == Some("Healthy")
                                        && c["status"].as_str() == Some("True")
                                })
                            })
                            .unwrap_or(false)
                    });
                if all_healthy {
                    return Ok(());
                }
            }
        }

        if start.elapsed() > timeout {
            bail!("Timed out waiting for Crossplane providers to be healthy on {context}");
        }
        std::thread::sleep(Duration::from_secs(10));
    }
}

pub fn wait_managed_ready(context: &str, timeout_secs: u64) -> Result<()> {
    use std::time::{Duration, Instant};
    let timeout = Duration::from_secs(timeout_secs);
    let start = Instant::now();

    loop {
        let output = Command::new("kubectl")
            .args(["--context", context, "get", "managed", "-o", "json"])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output();

        if let Ok(ref o) = output
            && o.status.success()
        {
            let json: serde_json::Value = serde_json::from_slice(&o.stdout).unwrap_or_default();
            if let Some(items) = json["items"].as_array() {
                if items.is_empty() {
                } else {
                    let all_ready = items.iter().all(|r| {
                        let conds = r["status"]["conditions"].as_array();
                        let synced = conds
                            .as_ref()
                            .map(|cs| {
                                cs.iter().any(|c| {
                                    c["type"].as_str() == Some("Synced")
                                        && c["status"].as_str() == Some("True")
                                })
                            })
                            .unwrap_or(false);
                        let ready = conds
                            .as_ref()
                            .map(|cs| {
                                cs.iter().any(|c| {
                                    c["type"].as_str() == Some("Ready")
                                        && c["status"].as_str() == Some("True")
                                })
                            })
                            .unwrap_or(false);
                        synced && ready
                    });
                    if all_ready {
                        return Ok(());
                    }
                }
            }
        }

        if start.elapsed() > timeout {
            bail!("Timed out waiting for managed resources on {context}");
        }
        println!(
            "  waiting for managed resources... ({}s)",
            start.elapsed().as_secs()
        );
        std::thread::sleep(Duration::from_secs(15));
    }
}

pub fn copy_external_names(bootstrap_ctx: &str, target_ctx: &str) -> Result<()> {
    let output = Command::new("kubectl")
        .args(["--context", bootstrap_ctx, "get", "managed", "-o", "json"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .context("Failed to list managed resources on bootstrap")?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!("kubectl get managed on {bootstrap_ctx} failed: {stderr}");
    }
    let json: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap_or_default();
    let items = match json["items"].as_array() {
        Some(items) => items,
        None => return Ok(()),
    };

    let mut copied = 0usize;
    let mut skipped = 0usize;
    for item in items {
        let external_name = item["metadata"]["annotations"]["crossplane.io/external-name"]
            .as_str()
            .unwrap_or("");
        if external_name.is_empty() {
            skipped += 1;
            continue;
        }
        let name = match item["metadata"]["name"].as_str() {
            Some(n) => n,
            None => continue,
        };
        let namespace = item["metadata"]["namespace"].as_str();
        let api_version = item["apiVersion"].as_str().unwrap_or("");
        let kind = item["kind"].as_str().unwrap_or("");
        let group = api_version.split_once('/').map(|(g, _)| g).unwrap_or("");
        if kind.is_empty() || group.is_empty() {
            continue;
        }
        let resource = format!("{}.{}/{}", kind.to_lowercase(), group, name);

        let mut args = vec![
            "--context",
            target_ctx,
            "annotate",
            "--overwrite",
            &resource,
            &format!("crossplane.io/external-name={external_name}"),
        ]
        .into_iter()
        .map(String::from)
        .collect::<Vec<_>>();
        if let Some(ns) = namespace
            && !ns.is_empty()
        {
            args.push("-n".into());
            args.push(ns.into());
        }

        let status = Command::new("kubectl")
            .args(&args)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output();
        match status {
            Ok(o) if o.status.success() => copied += 1,
            Ok(o) => {
                let stderr = String::from_utf8_lossy(&o.stderr);
                eprintln!(
                    "  warning: could not annotate {resource} on {target_ctx}: {}",
                    stderr.trim()
                );
            }
            Err(e) => {
                eprintln!("  warning: kubectl annotate failed for {resource}: {e}");
            }
        }
    }
    println!(
        "  copied external-name on {copied} resource(s){}",
        if skipped > 0 {
            format!(" ({skipped} skipped, no external-name on bootstrap yet)")
        } else {
            String::new()
        }
    );
    Ok(())
}

pub fn orphan_managed_resources(context: &str) -> Result<()> {
    let status = Command::new("kubectl")
        .args([
            "--context",
            context,
            "patch",
            "managed",
            "--all",
            "--type=merge",
            "-p",
            r#"{"spec":{"deletionPolicy":"Orphan"}}"#,
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .status()
        .context("Failed to orphan managed resources")?;

    if !status.success() {
        eprintln!("Warning: failed to orphan some managed resources");
    }
    Ok(())
}

fn parse_timeout(timeout: &str) -> std::time::Duration {
    let s = timeout.trim_end_matches('m').trim_end_matches('s');
    if timeout.ends_with('m') {
        std::time::Duration::from_secs(s.parse::<u64>().unwrap_or(10) * 60)
    } else {
        std::time::Duration::from_secs(s.parse::<u64>().unwrap_or(600))
    }
}

pub fn merge_kubeconfig(kubeconfig_path: &Path, context_name: &str) -> Result<()> {
    println!(
        "{} Merging kubeconfig for context '{context_name}'...",
        style(">>>").cyan()
    );

    let default_kubeconfig =
        PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string()))
            .join(".kube")
            .join("config");

    let kubeconfig_env = format!(
        "{}:{}",
        kubeconfig_path.display(),
        default_kubeconfig.display()
    );

    let output = Command::new("kubectl")
        .env("KUBECONFIG", &kubeconfig_env)
        .args(["config", "view", "--flatten"])
        .output()?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!("Failed to merge kubeconfig: {stderr}");
    }

    std::fs::write(&default_kubeconfig, &output.stdout)?;

    println!("{} Kubeconfig merged", style(">>>").green());

    Ok(())
}

pub fn get_unhealthy_pods(context: &str) -> Result<Vec<serde_json::Value>> {
    let output = Command::new("kubectl")
        .args(["--context", context, "get", "pods", "-A", "-o", "json"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .context("Failed to run kubectl get pods")?;

    if !output.status.success() {
        return Ok(vec![]);
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

pub fn get_warning_events(context: &str, since_minutes: u32) -> Result<Vec<serde_json::Value>> {
    let output = Command::new("kubectl")
        .args([
            "--context",
            context,
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
        return Ok(vec![]);
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

pub fn get_pod_logs(
    context: &str,
    namespace: &str,
    pod_name: &str,
    tail_lines: u32,
) -> Result<String> {
    let output = Command::new("kubectl")
        .args([
            "--context",
            context,
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

pub fn get_node_status(context: &str) -> Result<Vec<serde_json::Value>> {
    let output = Command::new("kubectl")
        .args(["--context", context, "get", "nodes", "-o", "json"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .context("Failed to run kubectl get nodes")?;

    if !output.status.success() {
        return Ok(vec![]);
    }

    let json: serde_json::Value =
        serde_json::from_slice(&output.stdout).unwrap_or(serde_json::Value::Null);

    Ok(json["items"].as_array().cloned().unwrap_or_default())
}

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

pub fn get_workload_readiness(context: &str, namespaces: &[String]) -> Result<Vec<Workload>> {
    let mut out = Vec::new();
    for namespace in namespaces {
        let output = Command::new("kubectl")
            .args([
                "--context",
                context,
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
    let output = Command::new("kubectl")
        .args(["--context", context, "get", "namespace", namespace])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    matches!(output, Ok(s) if s.success())
}

pub fn strip_finalizers_in_terminating_namespaces(kube_ctx: &str, namespaces: &[String]) {
    let mut list = Command::new("kubectl");
    list.args([
        "--context",
        kube_ctx,
        "get",
        "crd",
        "-o",
        r#"jsonpath={range .items[?(@.spec.scope=="Namespaced")]}{.spec.names.plural}.{.spec.group}{"\n"}{end}"#,
    ]);
    let crd_names: Vec<String> = run_capture(&mut list)
        .unwrap_or_default()
        .lines()
        .filter(|l| !l.is_empty())
        .map(String::from)
        .collect();

    for kind in &crd_names {
        for ns in namespaces {
            let mut get = Command::new("kubectl");
            get.args([
                "--context",
                kube_ctx,
                "-n",
                ns,
                "get",
                kind,
                "-o",
                "jsonpath={.items[*].metadata.name}",
            ]);
            let names: Vec<String> = run_capture(&mut get)
                .unwrap_or_default()
                .split_whitespace()
                .map(String::from)
                .collect();
            if names.is_empty() {
                continue;
            }
            for name in &names {
                let mut patch = Command::new("kubectl");
                patch.args([
                    "--context",
                    kube_ctx,
                    "-n",
                    ns,
                    "patch",
                    &format!("{kind}/{name}"),
                    "--type=merge",
                    "-p",
                    r#"{"metadata":{"finalizers":[]}}"#,
                ]);
                if run_capture(&mut patch).is_ok() {
                    println!(
                        "{}   stripped finalizers: {}/{}/{}",
                        style(">>>").dim(),
                        ns,
                        kind,
                        name
                    );
                }
            }
        }
    }
}

pub fn cleanup_kubeconfig(cluster_name: &str) -> Result<()> {
    let kubeconfig_path = dirs::home_dir()
        .context("Could not find home directory")?
        .join(".kube")
        .join(format!("{}.kubeconfig", cluster_name));

    if kubeconfig_path.exists() {
        std::fs::remove_file(&kubeconfig_path)
            .with_context(|| format!("Failed to remove {}", kubeconfig_path.display()))?;
        println!(
            "{} Removed {}",
            style(">>>").green(),
            kubeconfig_path.display()
        );
    }

    delete_kubeconfig_context(&format!("{}-admin@{}", cluster_name, cluster_name))?;
    delete_kubeconfig_context(cluster_name)?;

    delete_kubeconfig_cluster(cluster_name)?;
    delete_kubeconfig_user(&format!("{}-admin", cluster_name))?;

    Ok(())
}

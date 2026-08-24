use std::process::Stdio;

use anyhow::{Context, Result, bail};
use console::style;

use super::*;

/// Poll until a CRD reports Established, or `timeout` elapses.
///
/// # Errors
///
/// If `timeout` is not a duration, if `context` is empty, or if the CRD is not
/// Established in time. A CRD that never appears is a timeout, not a distinct
/// error: a provider registers its CRDs when it is ready and not before.
pub fn wait_crd_established(context: &str, crd_name: &str, timeout: &str) -> Result<()> {
    use std::time::{Duration, Instant};

    let timeout_duration = parse_timeout(timeout)
        .with_context(|| format!("'{timeout}' is not a duration (expected e.g. 30s, 10m, 1h)"))?;
    let start = Instant::now();

    loop {
        let result = super::run::command()
            .args([
                "--context",
                crate::io::kube_context::require_named(context)?,
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

pub fn unhealthy_provider_names(providers: &serde_json::Value) -> Vec<String> {
    let Some(items) = providers["items"].as_array() else {
        return Vec::new();
    };
    items
        .iter()
        .filter(|p| {
            !p["status"]["conditions"]
                .as_array()
                .map(|conds| {
                    conds.iter().any(|c| {
                        c["type"].as_str() == Some("Healthy")
                            && c["status"].as_str() == Some("True")
                    })
                })
                .unwrap_or(false)
        })
        .map(|p| {
            p["metadata"]["name"]
                .as_str()
                .unwrap_or("<unnamed>")
                .to_string()
        })
        .collect()
}

/// Poll until every installed Crossplane provider is Healthy, up to 300s.
///
/// # Errors
///
/// If `context` is empty, or the deadline passes. The message distinguishes no
/// providers installed from providers installed but unhealthy, because zero
/// providers would otherwise satisfy "all healthy" vacuously.
pub fn wait_crossplane_healthy(context: &str) -> Result<()> {
    use std::time::{Duration, Instant};
    let timeout = Duration::from_secs(300);
    let start = Instant::now();
    let mut last_report = Instant::now();
    let mut waiting_on: Vec<String> = Vec::new();

    loop {
        let output = super::run::command()
            .args([
                "--context",
                crate::io::kube_context::require_named(context)?,
                "get",
                "providers",
                "-o",
                "json",
            ])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output();

        if let Ok(ref o) = output
            && o.status.success()
        {
            let json: serde_json::Value = serde_json::from_slice(&o.stdout).unwrap_or_default();
            let installed = json["items"].as_array().map(|i| i.len()).unwrap_or(0);
            waiting_on = unhealthy_provider_names(&json);

            if installed > 0 && waiting_on.is_empty() {
                return Ok(());
            }

            if last_report.elapsed() >= Duration::from_secs(30) {
                println!(
                    "{} waiting for {} Crossplane provider(s) on '{context}': {} ({}s elapsed)",
                    style(">>>").yellow(),
                    waiting_on.len().max(1),
                    if waiting_on.is_empty() {
                        "none installed yet".to_string()
                    } else {
                        waiting_on.join(", ")
                    },
                    start.elapsed().as_secs(),
                );
                last_report = Instant::now();
            }
        }

        if start.elapsed() > timeout {
            if waiting_on.is_empty() {
                bail!(
                    "no Crossplane providers are installed on '{context}' after {}s, so none \
                     could become healthy",
                    timeout.as_secs(),
                );
            }
            bail!(
                "these Crossplane providers on '{context}' were not Healthy after {}s: {}",
                timeout.as_secs(),
                waiting_on.join(", "),
            );
        }
        std::thread::sleep(Duration::from_secs(10));
    }
}

/// Poll until every managed resource is both Synced and Ready.
///
/// # Errors
///
/// If `context` is empty, or the deadline passes. A cluster with no managed
/// resources yet keeps waiting rather than returning, so this cannot succeed
/// before the resources exist.
pub fn wait_managed_ready(context: &str, timeout_secs: u64) -> Result<()> {
    use std::time::{Duration, Instant};
    let timeout = Duration::from_secs(timeout_secs);
    let start = Instant::now();

    loop {
        let output = super::run::command()
            .args([
                "--context",
                crate::io::kube_context::require_named(context)?,
                "get",
                "managed",
                "-o",
                "json",
            ])
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AnnotateTarget {
    pub resource: String,
    pub namespace: Option<String>,
    pub external_name: String,
}

impl AnnotateTarget {
    pub(crate) fn annotate_args(&self, target_ctx: &str) -> Vec<String> {
        let mut args: Vec<String> = [
            "--context",
            target_ctx,
            "annotate",
            "--overwrite",
            &self.resource,
            &format!("crossplane.io/external-name={}", self.external_name),
        ]
        .into_iter()
        .map(String::from)
        .collect();

        if let Some(ns) = self.namespace.as_deref().filter(|ns| !ns.is_empty()) {
            args.push("-n".into());
            args.push(ns.into());
        }
        args
    }
}

fn external_name_of(item: &serde_json::Value) -> &str {
    item["metadata"]["annotations"]["crossplane.io/external-name"]
        .as_str()
        .unwrap_or("")
}

fn target_of(item: &serde_json::Value, external_name: &str) -> Option<AnnotateTarget> {
    let name = item["metadata"]["name"].as_str()?;
    let kind = item["kind"].as_str().unwrap_or("");
    let group = item["apiVersion"]
        .as_str()
        .unwrap_or("")
        .split_once('/')
        .map(|(g, _)| g)
        .unwrap_or("");

    if kind.is_empty() || group.is_empty() {
        return None;
    }

    Some(AnnotateTarget {
        resource: format!("{}.{}/{}", kind.to_lowercase(), group, name),
        namespace: item["metadata"]["namespace"].as_str().map(String::from),
        external_name: external_name.to_string(),
    })
}

pub fn external_name_targets(json: &serde_json::Value) -> (Vec<AnnotateTarget>, usize) {
    let Some(items) = json["items"].as_array() else {
        return (Vec::new(), 0);
    };

    let mut targets = Vec::new();
    let mut without_an_external_name = 0usize;

    for item in items {
        let external_name = external_name_of(item);
        if external_name.is_empty() {
            without_an_external_name += 1;
            continue;
        }
        if let Some(target) = target_of(item, external_name) {
            targets.push(target);
        }
    }

    (targets, without_an_external_name)
}

/// Carry `crossplane.io/external-name` from the bootstrap cluster to the
/// pivoted one, so the new Crossplane adopts the cloud resources rather than
/// creating second copies.
///
/// # Errors
///
/// If either context is empty, if listing managed resources on the bootstrap
/// fails, or if that listing is not JSON. A resource that fails to annotate is
/// a warning, not an error, so success does not mean every name was copied;
/// the count is printed.
pub fn copy_external_names(bootstrap_ctx: &str, target_ctx: &str) -> Result<()> {
    let bootstrap_ctx = crate::io::kube_context::require_named(bootstrap_ctx)?;
    crate::io::kube_context::require_named(target_ctx)?;

    let output = super::run::command()
        .args(["--context", bootstrap_ctx, "get", "managed", "-o", "json"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .context("Failed to list managed resources on bootstrap")?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!("kubectl get managed on {bootstrap_ctx} failed: {stderr}");
    }
    // Not unwrap_or_default: an empty document has no items, so a parse
    // failure would look exactly like "nothing to copy" and this would report
    // success having copied nothing.
    let json: serde_json::Value = serde_json::from_slice(&output.stdout)
        .context("kubectl get managed returned something that is not JSON")?;
    let (targets, skipped) = external_name_targets(&json);

    let mut copied = 0usize;
    for target in &targets {
        let status = super::run::command()
            .args(target.annotate_args(target_ctx))
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output();
        match status {
            Ok(o) if o.status.success() => copied += 1,
            Ok(o) => {
                let stderr = String::from_utf8_lossy(&o.stderr);
                eprintln!(
                    "  warning: could not annotate {} on {target_ctx}: {}",
                    target.resource,
                    stderr.trim()
                );
            }
            Err(e) => {
                eprintln!(
                    "  warning: kubectl annotate failed for {}: {e}",
                    target.resource
                );
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

/// Set every managed resource to `deletionPolicy: Orphan`.
///
/// # Errors
///
/// If `context` is empty, or the patch fails. The message says what is at
/// stake, because the caller's next step destroys the cluster and unorphaned
/// resources would take the real cloud resources with them.
pub fn orphan_managed_resources(context: &str) -> Result<()> {
    let status = super::run::command()
        .args([
            "--context",
            crate::io::kube_context::require_named(context)?,
            "patch",
            "managed",
            "--all",
            "--type=merge",
            "-p",
            r#"{"spec":{"deletionPolicy":"Orphan"}}"#,
        ])
        .output()
        .context("Failed to orphan managed resources")?;

    if !status.status.success() {
        bail!(
            "could not orphan managed resources on '{context}': {}\n    \
             They still carry deletionPolicy: Delete, so destroying the bootstrap \
             cluster would let Crossplane reap the real cloud resources.",
            String::from_utf8_lossy(&status.stderr).trim(),
        );
    }
    Ok(())
}

pub fn is_crossplane_managed(kind: &str) -> bool {
    kind.ends_with(".crossplane.io")
        || kind.ends_with(".upbound.io")
        || kind.contains(".crossplane.io/")
}

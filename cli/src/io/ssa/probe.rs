use std::process::Command;

use anyhow::{Context, Result, bail};
use console::style;

use crate::config::Context as CataContext;

#[derive(serde::Deserialize, Debug)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum ReadyProbe {
    Condition {
        resource: String,
        #[serde(default)]
        namespace: Option<String>,
        condition: String,
        #[serde(default)]
        timeout: Option<String>,
    },
    Jsonpath {
        resource: String,
        #[serde(default)]
        namespace: Option<String>,
        jsonpath: String,
        #[serde(default)]
        value: Option<serde_json::Value>,
        #[serde(default)]
        timeout: Option<String>,
    },
    Exists {
        resource: String,
        #[serde(default)]
        namespace: Option<String>,
        #[serde(default)]
        timeout: Option<String>,
    },
    Pod {
        image: String,
        command: Vec<String>,
        #[serde(default)]
        args: Vec<String>,
        #[serde(default)]
        namespace: Option<String>,
        #[serde(default)]
        timeout: Option<String>,
    },
    #[serde(rename = "kubectl-wait")]
    KubectlWait {
        args: Vec<String>,
    },
    Script {
        body: String,
    },
}

impl ReadyProbe {
    pub fn target(&self) -> Option<&str> {
        match self {
            ReadyProbe::Condition { resource, .. }
            | ReadyProbe::Jsonpath { resource, .. }
            | ReadyProbe::Exists { resource, .. } => Some(resource),
            _ => None,
        }
    }
}

pub(super) fn run_ready_probe(
    ctx: &CataContext,
    kube_context: &str,
    bundle_key: &str,
    probe: &ReadyProbe,
    fallback_timeout: &str,
    dry_run: bool,
) -> Result<()> {
    match probe {
        ReadyProbe::Condition { .. } => {
            probe_condition(kube_context, bundle_key, probe, fallback_timeout, dry_run)
        }
        ReadyProbe::Jsonpath { .. } => {
            probe_jsonpath(kube_context, bundle_key, probe, fallback_timeout, dry_run)
        }
        ReadyProbe::Exists { .. } => {
            probe_exists(kube_context, bundle_key, probe, fallback_timeout, dry_run)
        }
        ReadyProbe::Pod { .. } => {
            probe_pod(kube_context, bundle_key, probe, fallback_timeout, dry_run)
        }
        ReadyProbe::KubectlWait { .. } => {
            probe_kubectl_wait(kube_context, bundle_key, probe, dry_run)
        }
        ReadyProbe::Script { .. } => probe_script(ctx, kube_context, bundle_key, probe, dry_run),
    }
}

fn probe_condition(
    kube_context: &str,
    bundle_key: &str,
    probe: &ReadyProbe,
    fallback_timeout: &str,
    dry_run: bool,
) -> Result<()> {
    match probe {
        ReadyProbe::Condition {
            resource,
            namespace,
            condition,
            timeout,
        } => {
            let timeout = timeout.as_deref().unwrap_or(fallback_timeout);
            let ns_args: Vec<String> = match namespace {
                Some(ns) => vec!["-n".into(), ns.clone()],
                None => vec![],
            };
            let mk_args = |for_arg: String| -> Vec<String> {
                let mut a: Vec<String> = vec!["--context".into(), kube_context.into()];
                a.extend(ns_args.iter().cloned());
                a.push("wait".into());
                a.push(for_arg);
                a.push(resource.clone());
                a.push(format!("--timeout={timeout}"));
                a
            };
            let create_args = mk_args("--for=create".into());
            let (res_kind, _res_name) = resource.split_once('/').unwrap_or((resource.as_str(), ""));
            let cond_for_arg = if condition.eq_ignore_ascii_case("Available") {
                match res_kind.to_ascii_lowercase().as_str() {
                    "statefulset" | "sts" | "statefulsets" => {
                        "--for=jsonpath={.status.readyReplicas}=1".into()
                    }
                    "daemonset" | "ds" | "daemonsets" => {
                        "--for=jsonpath={.status.numberReady}=1".into()
                    }
                    _ => format!("--for=condition={condition}"),
                }
            } else {
                format!("--for=condition={condition}")
            };
            let cond_args = mk_args(cond_for_arg);
            if dry_run {
                println!(
                    "{} Would kubectl {} then kubectl {} (readyProbe for '{bundle_key}')",
                    style(">>>").yellow(),
                    create_args.join(" "),
                    cond_args.join(" "),
                );
                return Ok(());
            }
            println!(
                "{} Waiting on readyProbe for '{bundle_key}' → {resource} condition={condition}",
                style(">>>").cyan(),
            );
            let create_status = crate::io::kubectl::command()
                .args(&create_args)
                .status()
                .context("running kubectl wait --for=create for readyProbe")?;
            if !create_status.success() {
                bail!(
                    "readyProbe for '{bundle_key}' ({resource}) never appeared within {timeout}: {create_status}"
                );
            }
            let cond_status = crate::io::kubectl::command()
                .args(&cond_args)
                .status()
                .context("running kubectl wait for readyProbe condition")?;
            if !cond_status.success() {
                bail!(
                    "readyProbe for '{bundle_key}' ({resource} condition={condition}) failed: {cond_status}"
                );
            }
            Ok(())
        }
        _ => unreachable!("dispatched on the same variant"),
    }
}

fn probe_jsonpath(
    kube_context: &str,
    bundle_key: &str,
    probe: &ReadyProbe,
    fallback_timeout: &str,
    dry_run: bool,
) -> Result<()> {
    match probe {
        ReadyProbe::Jsonpath {
            resource,
            namespace,
            jsonpath,
            value,
            timeout,
        } => {
            let timeout = timeout.as_deref().unwrap_or(fallback_timeout);
            let mk_args = |for_arg: String| -> Vec<String> {
                let mut a: Vec<String> = vec!["--context".into(), kube_context.into()];
                if let Some(ns) = namespace {
                    a.push("-n".into());
                    a.push(ns.clone());
                }
                a.push("wait".into());
                a.push(for_arg);
                a.push(resource.clone());
                a.push(format!("--timeout={timeout}"));
                a
            };
            let create_args = mk_args("--for=create".into());
            let suffix = match value {
                Some(serde_json::Value::String(s)) => format!("={s}"),
                Some(v) => format!("={v}"),
                None => String::new(),
            };
            let path_args = mk_args(format!("--for=jsonpath={jsonpath}{suffix}"));
            if dry_run {
                println!(
                    "{} Would kubectl {} then kubectl {} (readyProbe for '{bundle_key}')",
                    style(">>>").yellow(),
                    create_args.join(" "),
                    path_args.join(" "),
                );
                return Ok(());
            }
            println!(
                "{} Waiting on readyProbe for '{bundle_key}' → {resource} jsonpath={jsonpath}{suffix}",
                style(">>>").cyan(),
            );
            let create_status = crate::io::kubectl::command()
                .args(&create_args)
                .status()
                .context("running kubectl wait --for=create for readyProbe")?;
            if !create_status.success() {
                bail!(
                    "readyProbe for '{bundle_key}' ({resource}) never appeared within {timeout}: {create_status}"
                );
            }
            let path_status = crate::io::kubectl::command()
                .args(&path_args)
                .status()
                .context("running kubectl wait --for=jsonpath for readyProbe")?;
            if !path_status.success() {
                bail!(
                    "readyProbe for '{bundle_key}' ({resource} jsonpath={jsonpath}{suffix}) failed: {path_status}"
                );
            }
            Ok(())
        }
        _ => unreachable!("dispatched on the same variant"),
    }
}

fn probe_exists(
    kube_context: &str,
    bundle_key: &str,
    probe: &ReadyProbe,
    fallback_timeout: &str,
    dry_run: bool,
) -> Result<()> {
    match probe {
        ReadyProbe::Exists {
            resource,
            namespace,
            timeout,
        } => {
            let timeout = timeout.as_deref().unwrap_or(fallback_timeout);
            let mut args: Vec<String> = vec!["--context".into(), kube_context.into()];
            if let Some(ns) = namespace {
                args.push("-n".into());
                args.push(ns.clone());
            }
            args.push("wait".into());
            args.push("--for=create".into());
            args.push(resource.clone());
            args.push(format!("--timeout={timeout}"));
            if dry_run {
                println!(
                    "{} Would kubectl {} (readyProbe for '{bundle_key}')",
                    style(">>>").yellow(),
                    args.join(" "),
                );
                return Ok(());
            }
            println!(
                "{} Waiting on readyProbe for '{bundle_key}' → {resource} exists",
                style(">>>").cyan(),
            );
            let status = crate::io::kubectl::command()
                .args(&args)
                .status()
                .context("running kubectl wait --for=create for readyProbe")?;
            if !status.success() {
                bail!(
                    "readyProbe for '{bundle_key}' ({resource}) never appeared within {timeout}: {status}"
                );
            }
            Ok(())
        }
        _ => unreachable!("dispatched on the same variant"),
    }
}

fn probe_pod(
    kube_context: &str,
    bundle_key: &str,
    probe: &ReadyProbe,
    fallback_timeout: &str,
    dry_run: bool,
) -> Result<()> {
    match probe {
        ReadyProbe::Pod {
            image,
            command,
            args,
            namespace,
            timeout,
        } => {
            let timeout = timeout.as_deref().unwrap_or(fallback_timeout);
            let ns = namespace.as_deref().unwrap_or("default");
            let slug: String = bundle_key
                .chars()
                .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
                .collect::<String>()
                .trim_matches('-')
                .to_ascii_lowercase();
            let stamp = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            let truncated: String = slug.chars().take(40).collect();
            let pod_name = format!("probe-{}-{stamp}", truncated.trim_matches('-'));

            let mut full: Vec<String> = vec![
                "--context".into(),
                kube_context.into(),
                "-n".into(),
                ns.into(),
                "run".into(),
                pod_name.clone(),
                "--rm".into(),
                "--attach".into(),
                "--restart=Never".into(),
                format!("--pod-running-timeout={timeout}"),
                format!("--image={image}"),
                "--command".into(),
                "--".into(),
            ];
            full.extend(command.iter().cloned());
            full.extend(args.iter().cloned());
            if dry_run {
                println!(
                    "{} Would kubectl {} (readyProbe for '{bundle_key}')",
                    style(">>>").yellow(),
                    full.join(" "),
                );
                return Ok(());
            }
            println!(
                "{} Waiting on readyProbe for '{bundle_key}' → in-cluster probe Pod {ns}/{pod_name} ({image})",
                style(">>>").cyan(),
            );
            let status = crate::io::kubectl::command()
                .args(&full)
                .status()
                .context("running kubectl run for readyProbe probe Pod")?;
            if !status.success() {
                bail!("readyProbe for '{bundle_key}' (probe Pod {ns}/{pod_name}) failed: {status}");
            }
            Ok(())
        }
        _ => unreachable!("dispatched on the same variant"),
    }
}

fn probe_kubectl_wait(
    kube_context: &str,
    bundle_key: &str,
    probe: &ReadyProbe,
    dry_run: bool,
) -> Result<()> {
    match probe {
        ReadyProbe::KubectlWait { args } => {
            let mut full: Vec<String> =
                vec!["--context".into(), kube_context.into(), "wait".into()];
            full.extend(args.iter().cloned());
            if dry_run {
                println!(
                    "{} Would kubectl {} (readyProbe for '{bundle_key}')",
                    style(">>>").yellow(),
                    full.join(" "),
                );
                return Ok(());
            }
            println!(
                "{} Waiting on readyProbe for '{bundle_key}' → kubectl-wait {}",
                style(">>>").cyan(),
                args.join(" "),
            );
            let status = crate::io::kubectl::command()
                .args(&full)
                .status()
                .context("running kubectl wait for readyProbe")?;
            if !status.success() {
                bail!("readyProbe for '{bundle_key}' (kubectl-wait) failed: {status}");
            }
            Ok(())
        }
        _ => unreachable!("dispatched on the same variant"),
    }
}

fn probe_script(
    ctx: &CataContext,
    kube_context: &str,
    bundle_key: &str,
    probe: &ReadyProbe,
    dry_run: bool,
) -> Result<()> {
    match probe {
        ReadyProbe::Script { body } => {
            if dry_run {
                println!(
                    "{} Would run readyProbe script for '{bundle_key}' ({} bytes)",
                    style(">>>").yellow(),
                    body.len(),
                );
                return Ok(());
            }
            println!(
                "{} Running readyProbe script for '{bundle_key}'",
                style(">>>").cyan(),
            );
            let _ = ctx;
            let status = Command::new("bash")
                .args(["-euo", "pipefail", "-c", body])
                .env("KUBE_CONTEXT", kube_context)
                .status()
                .context("running readyProbe script")?;
            if !status.success() {
                bail!("readyProbe script for '{bundle_key}' failed: {status}");
            }
            Ok(())
        }
        _ => unreachable!("dispatched on the same variant"),
    }
}

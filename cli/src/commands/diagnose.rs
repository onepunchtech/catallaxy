use anyhow::{Context as _, Result, bail};
use clap::Args;
use console::style;

use crate::config::Context as CataContext;
use crate::domain::lab::kube_context_in;
use crate::domain::{ClusterSpec, FloeSpec};
use crate::io;

#[derive(Args)]
pub struct DiagnoseArgs {
    #[arg(help = "Cluster to inspect. Defaults to the flake fragment")]
    cluster: Option<String>,

    #[arg(long, help = "Inspect every cluster in the lab")]
    all: bool,

    #[arg(
        long,
        default_value = "20",
        value_name = "N",
        help = "Log lines to show per unhealthy pod"
    )]
    tail: u32,

    #[arg(
        long,
        default_value = "30",
        value_name = "MINUTES",
        help = "How far back to look for warning events"
    )]
    since: u32,
}

pub async fn run(ctx: &CataContext, args: DiagnoseArgs) -> Result<()> {
    if args.all {
        return diagnose_all(ctx, &args).await;
    }

    let lab_name = ctx.resolve_lab_name(None)?;
    let lab = crate::io::nix::get_lab_config(ctx, &lab_name)?;

    let cluster_name = match &args.cluster {
        Some(name) => name.clone(),
        None => {
            let names: Vec<String> = lab["clusterNames"]
                .as_array()
                .map(|arr| {
                    arr.iter()
                        .filter_map(|v| v.as_str().map(String::from))
                        .collect()
                })
                .unwrap_or_default();
            if names.len() == 1 {
                names[0].clone()
            } else {
                bail!(
                    "Multiple clusters in lab. Specify one: {} (or use --all)",
                    names.join(", ")
                );
            }
        }
    };

    let cluster_config = crate::io::nix::get_cluster_config_from_lab(&lab, &cluster_name)?;
    let context = kube_context_in(&lab, &cluster_name)?.to_string();

    diagnose_cluster(ctx, &cluster_name, &context, &cluster_config, &args).await
}

async fn diagnose_all(ctx: &CataContext, args: &DiagnoseArgs) -> Result<()> {
    let lab_name = ctx.resolve_lab_name(None)?;
    let lab = crate::io::nix::get_lab_config(ctx, &lab_name)?;

    let cluster_names: Vec<String> = lab["clusterNames"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();

    for cluster_name in &cluster_names {
        let cluster_config = crate::io::nix::get_cluster_config_from_lab(&lab, cluster_name)?;
        let context = kube_context_in(&lab, cluster_name)?.to_string();
        diagnose_cluster(ctx, cluster_name, &context, &cluster_config, args).await?;
        println!();
    }

    Ok(())
}

async fn diagnose_cluster(
    _ctx: &CataContext,
    cluster_name: &str,
    kube_context: &str,
    cluster_config: &serde_json::Value,
    args: &DiagnoseArgs,
) -> Result<()> {
    println!(
        "{} Diagnosing cluster '{}'",
        style("catallaxy").cyan().bold(),
        style(cluster_name).green()
    );
    println!();

    if !io::kubectl::api_reachable(kube_context) {
        println!(
            "  {} API server unreachable (context: {})",
            style("UNREACHABLE").red().bold(),
            kube_context
        );
        println!("  Cannot diagnose an unreachable cluster.");
        return Ok(());
    }
    println!("  {} API server reachable", style("OK").green().bold());

    print_node_status(kube_context)?;

    print_kapp_status(kube_context)?;

    print_component_health(kube_context, cluster_config)?;

    print_unhealthy_pods(kube_context, args.tail)?;

    print_stuck_deployments(kube_context)?;

    print_warning_events(kube_context, args.since)?;

    Ok(())
}

fn print_node_status(context: &str) -> Result<()> {
    let nodes = io::kubectl::get_node_status(context)?;
    if nodes.is_empty() {
        println!("  {} No nodes found", style("WARN").yellow().bold());
        return Ok(());
    }

    println!();
    println!("  {}", style("Nodes:").bold());
    for node in &nodes {
        let name = node["metadata"]["name"].as_str().unwrap_or("?");
        let conditions = node["status"]["conditions"].as_array();
        let ready = conditions
            .map(|conds| {
                conds.iter().any(|c| {
                    c["type"].as_str() == Some("Ready") && c["status"].as_str() == Some("True")
                })
            })
            .unwrap_or(false);

        let status = if ready {
            style("Ready").green()
        } else {
            style("NotReady").red()
        };

        let version = node["status"]["nodeInfo"]["kubeletVersion"]
            .as_str()
            .unwrap_or("?");

        println!("    {} [{}] {}", style(name).cyan(), status, version);
    }

    Ok(())
}

fn print_kapp_status(context: &str) -> Result<()> {
    let apps = io::kubectl::get_kapp_app_statuses(context)?;
    if apps.is_empty() {
        return Ok(());
    }

    println!();
    println!("  {}", style("Kapp Apps:").bold());
    for (name, status, age) in &apps {
        let display_name = name.strip_prefix("cata-").unwrap_or(name);
        let status_styled =
            if status.contains("Succeeded") || status.contains("Reconcile succeeded") {
                style(status).green()
            } else if status.contains("Failed") {
                style(status).red()
            } else {
                style(status).yellow()
            };

        if age.is_empty() {
            println!("    {} [{}]", style(display_name).cyan(), status_styled);
        } else {
            println!(
                "    {} [{}] ({})",
                style(display_name).cyan(),
                status_styled,
                style(age).dim()
            );
        }
    }

    Ok(())
}

fn print_component_health(context: &str, config: &serde_json::Value) -> Result<()> {
    let spec =
        ClusterSpec::from_value(config.clone()).context("parsing the evaluated cluster config")?;
    let enabled: Vec<(&String, &FloeSpec)> = spec.enabled_floes().collect();

    if enabled.is_empty() {
        return Ok(());
    }

    println!();
    println!("  {}", style("Floes:").bold());

    for (name, floe) in &enabled {
        let namespace = floe.namespace.as_deref().unwrap_or(name);
        let version = floe.version.as_deref().unwrap_or("?");

        let ns_health = check_namespace_health(context, namespace);
        let (status, detail) = match ns_health {
            NamespaceHealth::AllReady(total) => (style("healthy").green(), format!("{total} pods")),
            NamespaceHealth::SomeNotReady(ready, total) => (
                style("degraded").yellow(),
                format!("{ready}/{total} pods ready"),
            ),
            NamespaceHealth::NoPods => (style("no pods").dim(), String::new()),
            NamespaceHealth::Error => (style("error").red(), String::new()),
        };

        if detail.is_empty() {
            println!(
                "    {} {} [{}]",
                style(name).cyan(),
                style(format!("v{version}")).dim(),
                status,
            );
        } else {
            println!(
                "    {} {} [{}] ({})",
                style(name).cyan(),
                style(format!("v{version}")).dim(),
                status,
                detail,
            );
        }
    }

    Ok(())
}

enum NamespaceHealth {
    AllReady(usize),
    SomeNotReady(usize, usize),
    NoPods,
    Error,
}

fn check_namespace_health(context: &str, namespace: &str) -> NamespaceHealth {
    use std::process::{Command, Stdio};

    let output = Command::new("kubectl")
        .args([
            "--context",
            context,
            "get",
            "pods",
            "-n",
            namespace,
            "-o",
            "json",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output();

    let output = match output {
        Ok(o) if o.status.success() => o,
        _ => return NamespaceHealth::Error,
    };

    let json: serde_json::Value = match serde_json::from_slice(&output.stdout) {
        Ok(v) => v,
        Err(_) => return NamespaceHealth::Error,
    };

    let items = match json["items"].as_array() {
        Some(items) if !items.is_empty() => items,
        _ => return NamespaceHealth::NoPods,
    };

    let total = items.len();
    let ready = items
        .iter()
        .filter(|pod| {
            let phase = pod["status"]["phase"].as_str().unwrap_or("");
            match phase {
                "Succeeded" | "Completed" => true,
                "Running" => pod["status"]["containerStatuses"]
                    .as_array()
                    .map(|statuses| {
                        statuses
                            .iter()
                            .all(|cs| cs["ready"].as_bool() == Some(true))
                    })
                    .unwrap_or(false),
                _ => false,
            }
        })
        .count();

    if ready == total {
        NamespaceHealth::AllReady(total)
    } else {
        NamespaceHealth::SomeNotReady(ready, total)
    }
}

fn print_unhealthy_pods(context: &str, tail_lines: u32) -> Result<()> {
    let unhealthy = io::kubectl::get_unhealthy_pods(context)?;
    if unhealthy.is_empty() {
        return Ok(());
    }

    println!();
    println!(
        "  {} ({} pod{})",
        style("Unhealthy Pods:").bold().red(),
        unhealthy.len(),
        if unhealthy.len() == 1 { "" } else { "s" }
    );

    for pod in &unhealthy {
        let ns = pod["metadata"]["namespace"].as_str().unwrap_or("?");
        let name = pod["metadata"]["name"].as_str().unwrap_or("?");
        let phase = pod["status"]["phase"].as_str().unwrap_or("Unknown");
        let reason = pod["status"]["reason"].as_str().unwrap_or("");

        let status_detail = if reason.is_empty() {
            phase.to_string()
        } else {
            format!("{phase}/{reason}")
        };

        println!(
            "    {} {}/{} [{}]",
            style("-").red(),
            style(ns).dim(),
            style(name).cyan(),
            style(&status_detail).red()
        );

        if let Some(statuses) = pod["status"]["containerStatuses"].as_array() {
            for cs in statuses {
                let container_name = cs["name"].as_str().unwrap_or("?");
                if let Some(waiting) = cs["state"]["waiting"].as_object() {
                    let msg = waiting
                        .get("message")
                        .and_then(|v| v.as_str())
                        .or_else(|| waiting.get("reason").and_then(|v| v.as_str()))
                        .unwrap_or("waiting");
                    println!(
                        "      {} {}: {}",
                        style("waiting").yellow(),
                        container_name,
                        msg
                    );
                } else if let Some(terminated) = cs["state"]["terminated"].as_object() {
                    let exit_code = terminated
                        .get("exitCode")
                        .and_then(|v| v.as_i64())
                        .unwrap_or(-1);
                    let reason = terminated
                        .get("reason")
                        .and_then(|v| v.as_str())
                        .unwrap_or("terminated");
                    println!(
                        "      {} {}: {} (exit {})",
                        style("terminated").red(),
                        container_name,
                        reason,
                        exit_code
                    );
                }
            }
        }

        if tail_lines > 0 {
            let logs = io::kubectl::get_pod_logs(context, ns, name, tail_lines).unwrap_or_default();
            if !logs.trim().is_empty() {
                let lines: Vec<&str> = logs.lines().collect();
                let show_lines = if lines.len() > tail_lines as usize {
                    &lines[lines.len() - tail_lines as usize..]
                } else {
                    &lines
                };
                println!("      {}:", style("logs").dim());
                for line in show_lines {
                    println!("        {}", style(line).dim());
                }
            }
        }
    }

    Ok(())
}

fn print_stuck_deployments(context: &str) -> Result<()> {
    let stuck = io::kubectl::get_stuck_deployments(context)?;
    if stuck.is_empty() {
        return Ok(());
    }

    println!();
    println!(
        "  {} ({} deployment{})",
        style("Stuck Deployments:").bold().yellow(),
        stuck.len(),
        if stuck.len() == 1 { "" } else { "s" }
    );

    for (ns, name) in &stuck {
        println!(
            "    {} {}/{}",
            style("-").yellow(),
            style(ns).dim(),
            style(name).cyan()
        );
    }
    println!(
        "    {} use 'kubectl rollout restart deployment/<name> -n <ns>' to retry",
        style("hint:").dim()
    );

    Ok(())
}

fn print_warning_events(context: &str, since_minutes: u32) -> Result<()> {
    let events = io::kubectl::get_warning_events(context, since_minutes)?;
    if events.is_empty() {
        return Ok(());
    }

    let mut event_counts: std::collections::BTreeMap<String, (u32, String, String)> =
        std::collections::BTreeMap::new();

    for event in &events {
        let ns = event["metadata"]["namespace"].as_str().unwrap_or("?");
        let message = event["message"].as_str().unwrap_or("?");
        let involved = event["involvedObject"]["name"].as_str().unwrap_or("?");
        let key = format!("{ns}/{involved}: {message}");
        let entry = event_counts
            .entry(key.clone())
            .or_insert((0, ns.to_string(), String::new()));
        entry.0 += 1;
        entry.2 = message.to_string();
    }

    let events_to_show: Vec<_> = event_counts.iter().take(15).collect();

    println!();
    println!(
        "  {} (last {} min, {} unique)",
        style("Warning Events:").bold().yellow(),
        since_minutes,
        event_counts.len()
    );

    for (key, (count, _ns, _msg)) in &events_to_show {
        let count_str = if *count > 1 {
            format!(" (x{count})")
        } else {
            String::new()
        };
        let display = if key.len() > 120 {
            format!("{}...", &key[..117])
        } else {
            key.to_string()
        };
        println!(
            "    {} {}{}",
            style("-").yellow(),
            display,
            style(&count_str).dim()
        );
    }

    if event_counts.len() > 15 {
        println!(
            "    {} ...and {} more",
            style("-").dim(),
            event_counts.len() - 15
        );
    }

    Ok(())
}

use anyhow::Result;
use console::style;

use crate::config::Context as CataContext;
use crate::io;

pub async fn list(ctx: &CataContext) -> Result<()> {
    println!("{} Defined labs", style("catallaxy").cyan().bold());
    println!();

    let labs = crate::io::nix::list_labs_with_cluster_counts(ctx)?;

    if labs.is_empty() {
        println!("  (no labs defined)");
        return Ok(());
    }

    for (name, cluster_count) in &labs {
        let unit = if *cluster_count == 1 {
            "cluster"
        } else {
            "clusters"
        };
        println!("  {} ({} {})", style(name).green(), cluster_count, unit);
    }

    Ok(())
}

pub async fn topology_cmd(ctx: &CataContext, name: &str, format: &str, live: bool) -> Result<()> {
    let lab = crate::io::nix::get_lab_config(ctx, name)?;
    let mut topo = crate::topology::extract::extract_static(&lab)?;

    if live {
        crate::topology::extract::enrich_live(ctx, &mut topo)?;
    }

    let fmt = format.parse::<crate::topology::TopologyFormat>()?;
    crate::topology::render::render(&topo, fmt)
}

#[derive(serde::Serialize)]
struct ServiceState {
    name: String,
    container: String,
    running: bool,
}

#[derive(serde::Serialize)]
struct ClusterState {
    name: String,
    context: String,
    reachable: bool,
}

#[derive(serde::Serialize)]
struct LabState {
    lab: String,
    services: Vec<ServiceState>,
    clusters: Vec<ClusterState>,
}

pub async fn status_json(ctx: &CataContext, name: &str) -> Result<()> {
    let lab = crate::io::nix::get_lab_config(ctx, name)?;

    let services = lab["services"]
        .as_object()
        .map(|svcs| {
            svcs.iter()
                .map(|(svc_name, svc)| {
                    let container = svc["container"].as_str().unwrap_or("").to_string();
                    ServiceState {
                        name: svc_name.clone(),
                        running: !container.is_empty() && io::docker::container_running(&container),
                        container,
                    }
                })
                .collect()
        })
        .unwrap_or_default();

    let clusters = lab["clusterNames"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str())
                .map(|cluster| {
                    let context = super::state::resolve_cluster_context(&lab, cluster);
                    ClusterState {
                        name: cluster.to_string(),
                        reachable: io::kubectl::api_reachable(&context),
                        context,
                    }
                })
                .collect()
        })
        .unwrap_or_default();

    println!(
        "{}",
        serde_json::to_string_pretty(&LabState {
            lab: name.to_string(),
            services,
            clusters,
        })?
    );
    Ok(())
}

pub async fn status(ctx: &CataContext, name: &str, json: bool) -> Result<()> {
    if json {
        return status_json(ctx, name).await;
    }

    println!(
        "{} Lab '{}' status",
        style("catallaxy").cyan().bold(),
        style(name).green()
    );
    println!();

    let lab = crate::io::nix::get_lab_config(ctx, name)?;

    let strategy = lab
        .pointer("/cd/strategy")
        .and_then(|v| v.as_str())
        .unwrap_or("kapp");
    let zone = lab
        .pointer("/dnsInfo/zone")
        .and_then(|v| v.as_str())
        .unwrap_or("?");
    println!(
        "  {} {} {}  {} {}",
        style("strategy:").dim(),
        strategy,
        style("|").dim(),
        style("zone:").dim(),
        zone
    );
    println!();

    print_service_status(&lab);
    print_cluster_status(&lab)?;

    Ok(())
}

fn print_service_status(lab: &serde_json::Value) {
    if let Some(services) = lab["services"].as_object()
        && !services.is_empty()
    {
        println!("{}", style("Services:").bold());
        for (svc_name, svc) in services {
            let container = svc["container"].as_str().unwrap_or("");
            let description = svc["description"].as_str().unwrap_or("");
            let running = if !container.is_empty() {
                io::docker::container_running(container)
            } else {
                false
            };
            let status_str = if running {
                style("running").green()
            } else {
                style("stopped").red()
            };

            let ports_str = svc["ports"]
                .as_array()
                .map(|arr| {
                    arr.iter()
                        .filter_map(|v| v.as_str())
                        .collect::<Vec<_>>()
                        .join(", ")
                })
                .unwrap_or_default();

            if ports_str.is_empty() {
                println!(
                    "  {} ({}) [{}]",
                    style(svc_name).cyan(),
                    description,
                    status_str
                );
            } else {
                println!(
                    "  {} ({}) [{}] {}",
                    style(svc_name).cyan(),
                    description,
                    status_str,
                    style(format!("[{ports_str}]")).dim()
                );
            }
        }
        println!();
    }
}

fn print_cluster_status(lab: &serde_json::Value) -> Result<()> {
    let cluster_names: Vec<String> = lab["clusterNames"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();

    println!("{}", style("Clusters:").bold());
    for cluster_name in &cluster_names {
        let context_name = super::state::resolve_cluster_context(lab, cluster_name);
        let reachable = io::kubectl::api_reachable(&context_name);

        let status_str = if reachable {
            style("ready").green()
        } else {
            style("not ready").yellow()
        };

        println!(
            "  {} [{}] (context: {})",
            style(cluster_name).green(),
            status_str,
            style(&context_name).dim(),
        );
    }
    println!();

    let total = cluster_names.len();
    let reachable_count = cluster_names
        .iter()
        .filter(|name| {
            let ctx = super::state::resolve_cluster_context(lab, name);
            io::kubectl::api_reachable(&ctx)
        })
        .count();

    println!(
        "{} {}/{} clusters reachable",
        style("Summary:").bold(),
        reachable_count,
        total,
    );
    if reachable_count < total {
        println!(
            "  {} run 'cata diagnose --all' for detailed diagnostics",
            style("hint:").dim(),
        );
    }
    println!(
        "  {} run 'cata lab topology' for detailed cluster/component view",
        style("hint:").dim(),
    );

    Ok(())
}

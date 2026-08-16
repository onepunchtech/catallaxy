use anyhow::Result;
use console::style;

use crate::config::Context as CataContext;
use crate::domain::LabSpec;
use crate::io;

pub async fn list(ctx: &CataContext) -> Result<()> {
    println!("{} Defined labs", style("catallaxy").cyan().bold());
    println!();

    let labs = crate::io::nix::list_labs_with_cluster_counts(ctx)?;

    if labs.is_empty() {
        println!("  (no labs defined)");
        return Ok(());
    }

    for (name, summary) in &labs {
        let unit = if summary.clusters == 1 {
            "cluster"
        } else {
            "clusters"
        };
        println!("  {} ({} {})", style(name).green(), summary.clusters, unit);
        if !summary.eligible {
            for reason in &summary.reasons {
                println!("      {} {}", style("needs").yellow(), reason);
            }
        }
    }

    Ok(())
}

pub async fn topology_cmd(
    ctx: &CataContext,
    name: &str,
    format: crate::topology::TopologyFormat,
    live: bool,
) -> Result<()> {
    let lab = crate::io::nix::get_lab_spec(ctx, name)?;
    let mut topo = crate::topology::extract::extract_static(&lab);

    if live {
        crate::topology::extract::enrich_live(ctx, &mut topo)?;
    }

    print!("{}", crate::topology::render::render(&topo, format)?);
    Ok(())
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
    let lab = crate::io::nix::get_lab_spec(ctx, name)?;

    let services = lab
        .services
        .iter()
        .map(|(svc_name, svc)| {
            let container = svc.container.clone();
            ServiceState {
                name: svc_name.clone(),
                running: !container.is_empty() && io::docker::container_running(&container),
                container,
            }
        })
        .collect();

    let clusters = lab
        .cluster_names
        .iter()
        .map(|cluster| {
            let context = lab.kube_context(cluster).unwrap_or_default().to_string();
            ClusterState {
                name: cluster.clone(),
                reachable: io::kubectl::api_reachable(&context),
                context,
            }
        })
        .collect::<Vec<_>>();

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

    let lab = crate::io::nix::get_lab_spec(ctx, name)?;

    if !io::docker::daemon_reachable() {
        println!(
            "  {} the docker daemon is not reachable, so every container below \
             reads as stopped whether or not the lab was ever started.",
            style("ERROR").red(),
        );
        println!("  Start docker (or check DOCKER_HOST) and run this again.");
        println!();
    }

    let strategy = lab.cd.strategy.tag();
    let zone = lab.dns_info.as_ref().map_or("?", |d| d.zone.as_str());
    println!(
        "  {} {} {} {} {}",
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

fn print_service_status(lab: &LabSpec) {
    if !lab.services.is_empty() {
        println!("{}", style("Services:").bold());
        for (svc_name, svc) in &lab.services {
            let container = svc.container.as_str();
            let description = svc.description.as_str();
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

            let ports_str = svc.ports.join(", ");

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

fn print_cluster_status(lab: &LabSpec) -> Result<()> {
    let cluster_names = &lab.cluster_names;

    println!("{}", style("Clusters:").bold());
    for cluster_name in cluster_names {
        let context_name = lab.kube_context(cluster_name).unwrap_or_default();
        let reachable = io::kubectl::api_reachable(context_name);

        let status_str = if reachable {
            style("ready").green()
        } else {
            style("not ready").yellow()
        };

        println!(
            "  {} [{}] (context: {})",
            style(cluster_name).green(),
            status_str,
            style(context_name).dim(),
        );
    }
    println!();

    let total = cluster_names.len();
    let reachable_count = cluster_names
        .iter()
        .filter(|name| io::kubectl::api_reachable(lab.kube_context(name).unwrap_or_default()))
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

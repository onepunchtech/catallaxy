use anyhow::Result;
use console::style;

use crate::config::Context as CataContext;
use crate::domain::LabSpec;
use crate::io;

#[derive(serde::Serialize)]
struct ListJson {
    defined: Vec<String>,
    running: Vec<RunningJson>,
    orphans: Vec<String>,
    docker_reachable: bool,
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct RunningJson {
    name: String,
    containers: Vec<String>,
    k3d_clusters: Vec<String>,
    flake: Option<String>,
    defined_here: bool,
}

pub fn list(ctx: &CataContext, json: bool) -> Result<()> {
    // Non-fatal on purpose: a lab whose flake no longer evaluates is one of
    // the ways a lab gets orphaned, and it must not hide its own leftovers.
    let defined = crate::io::nix::list_labs_with_cluster_counts(ctx);
    let inventory = crate::domain::inventory::correlate(&io::host_inventory::gather());

    if json {
        let defined_names: Vec<String> = defined
            .as_ref()
            .map(|labs| labs.iter().map(|(n, _)| n.clone()).collect())
            .unwrap_or_default();
        let out = ListJson {
            running: inventory
                .labs
                .iter()
                .map(|lab| RunningJson {
                    name: lab.name.clone(),
                    containers: lab.containers.clone(),
                    k3d_clusters: lab.k3d_clusters.clone(),
                    flake: match &lab.origin {
                        crate::domain::inventory::Origin::One(f) => Some(f.clone()),
                        _ => None,
                    },
                    defined_here: defined_names.contains(&lab.name),
                })
                .collect(),
            orphans: inventory.orphans.iter().map(describe_orphan).collect(),
            docker_reachable: inventory.docker_reachable,
            defined: defined_names,
        };
        println!("{}", serde_json::to_string_pretty(&out)?);
        return Ok(());
    }

    print_defined(&defined);

    print_running(&inventory, &defined)
}

fn print_defined(defined: &Result<Vec<(String, crate::io::nix::LabSummary)>>) {
    println!("{} Defined labs", style("catallaxy").cyan().bold());
    println!();
    match defined {
        Err(e) => println!(
            "  {} this flake could not be evaluated: {e}",
            style("note:").yellow()
        ),
        Ok(labs) if labs.is_empty() => println!("  (no labs defined)"),
        Ok(labs) => {
            for (name, summary) in labs {
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
        }
    }
}

fn print_running(
    inventory: &crate::domain::inventory::Inventory,
    defined: &Result<Vec<(String, crate::io::nix::LabSummary)>>,
) -> Result<()> {
    println!();
    println!("{}", style("Running on this host").bold());
    println!();

    if !inventory.docker_reachable {
        println!(
            "  {} docker is not reachable, so nothing is known about what is running",
            style("note:").yellow()
        );
        return Ok(());
    }

    if inventory.labs.is_empty() && inventory.orphans.is_empty() {
        println!("  (nothing)");
        return Ok(());
    }

    let defined_names: Vec<&str> = defined
        .as_ref()
        .map(|labs| labs.iter().map(|(n, _)| n.as_str()).collect())
        .unwrap_or_default();

    for lab in &inventory.labs {
        let here = if defined_names.contains(&lab.name.as_str()) {
            style("(defined here)").dim().to_string()
        } else {
            style("(not in this flake)").yellow().to_string()
        };
        println!("  {} {}", style(&lab.name).green(), here);

        if !lab.containers.is_empty() {
            println!("      services: {}", lab.containers.join(", "));
        }
        if !lab.k3d_clusters.is_empty() {
            println!("      clusters: {}", lab.k3d_clusters.join(", "));
        }
        match &lab.origin {
            crate::domain::inventory::Origin::One(flake) => {
                println!("      flake:    {}", style(flake).dim());
            }
            crate::domain::inventory::Origin::Conflicting(all) => {
                println!(
                    "      {} run from more than one checkout: {}",
                    style("flake:").yellow(),
                    all.join(", ")
                );
            }
            crate::domain::inventory::Origin::Unknown => {}
        }
        if !lab.has_record {
            println!(
                "      {} no record of what it put here; cleanup works from what is visible",
                style("note:").dim()
            );
        }
        println!(
            "      remove:   cata lab cleanup {}",
            style(&lab.name).dim()
        );
    }

    if !inventory.orphans.is_empty() {
        println!();
        println!("{}", style("Claimed by no lab").bold());
        println!();
        for orphan in &inventory.orphans {
            println!("  {}", describe_orphan(orphan));
        }
        println!();
        println!("      remove:   cata lab cleanup --orphans");
    }

    Ok(())
}

fn describe_orphan(orphan: &crate::domain::inventory::Orphan) -> String {
    use crate::domain::inventory::Orphan;
    match orphan {
        Orphan::UnattributedContainer { name, published } => {
            let ports = if published.is_empty() {
                String::new()
            } else {
                format!(
                    " holding port(s) {}",
                    published
                        .iter()
                        .map(u16::to_string)
                        .collect::<Vec<_>>()
                        .join(", ")
                )
            };
            format!("container {name}{ports}, created before catallaxy labelled containers")
        }
        Orphan::UnknownK3dCluster { name } => {
            format!("k3d cluster {name}, which no lab record claims")
        }
        Orphan::StaleRecordOnly { lab } => {
            format!("a record for lab '{lab}', but nothing of it is running")
        }
    }
}

pub fn topology_cmd(
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
    /// Why the context could not be resolved, when it could not.
    ///
    /// `reachable` stays a plain bool so existing consumers keep working, but
    /// false used to mean two different things: the cluster did not answer, or
    /// the lab never told us which cluster to ask. The second used to read as
    /// reachable, because an empty context makes kubectl fall back to whatever
    /// the operator is pointed at.
    #[serde(skip_serializing_if = "Option::is_none")]
    context_error: Option<String>,
}

#[derive(serde::Serialize)]
struct LabState {
    lab: String,
    services: Vec<ServiceState>,
    clusters: Vec<ClusterState>,
}

pub fn status_json(ctx: &CataContext, name: &str) -> Result<()> {
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
        .map(|cluster| match lab.kube_context(cluster) {
            Ok(context) => ClusterState {
                name: cluster.clone(),
                reachable: io::kubectl::api_reachable(context),
                context: context.to_string(),
                context_error: None,
            },
            Err(e) => ClusterState {
                name: cluster.clone(),
                reachable: false,
                context: String::new(),
                context_error: Some(e.to_string()),
            },
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

pub fn status(ctx: &CataContext, name: &str, json: bool) -> Result<()> {
    if json {
        return status_json(ctx, name);
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
    let mut reachable_count = 0;
    for cluster_name in cluster_names {
        let context = match lab.kube_context(cluster_name) {
            Ok(context) => context,
            Err(e) => {
                println!(
                    "  {} [{}] {}",
                    style(cluster_name).green(),
                    style("context unresolved").red(),
                    style(e).dim(),
                );
                continue;
            }
        };

        let reachable = io::kubectl::api_reachable(context);
        if reachable {
            reachable_count += 1;
        }

        let status_str = if reachable {
            style("ready").green()
        } else {
            style("not ready").yellow()
        };

        println!(
            "  {} [{}] (context: {})",
            style(cluster_name).green(),
            status_str,
            style(context).dim(),
        );
    }
    println!();

    let total = cluster_names.len();

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

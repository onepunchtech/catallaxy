use std::path::PathBuf;

use anyhow::{Context as _, Result, bail};
use console::style;

use crate::config::Context as CataContext;
use crate::domain::CdConfig;
use crate::io;
use crate::lint;

pub async fn run(
    ctx: &CataContext,
    name: Option<String>,
    path: Option<PathBuf>,
    skip: Vec<String>,
) -> Result<()> {
    println!("{} Environment", style("catallaxy").cyan().bold(),);
    let tool_results = io::process::check_all_tools();
    let mut missing_tools = Vec::new();
    for (name, found, info) in &tool_results {
        if *found {
            println!("  {} {}", style("✓").green(), name);
        } else {
            println!("  {} {} ({})", style("✗").red(), name, info);
            missing_tools.push(name.as_str());
        }
    }
    println!();

    if !missing_tools.is_empty() {
        println!(
            "{} Missing tools: {}",
            style("Warning:").yellow(),
            missing_tools.join(", ")
        );
        println!();
    }

    let lab_name = match &path {
        Some(_) => None,
        None => Some(ctx.resolve_lab_name(name.as_deref())?),
    };

    if let Some(ref lab_name) = lab_name {
        println!("{} Configuration", style("catallaxy").cyan().bold());
        match crate::io::nix::get_lab_config(ctx, lab_name) {
            Ok(lab) => {
                let cluster_names: Vec<&str> = lab["clusterNames"]
                    .as_array()
                    .map(|arr| arr.iter().filter_map(|v| v.as_str()).collect())
                    .unwrap_or_default();
                let cd: CdConfig = serde_json::from_value(lab["cd"].clone())
                    .context("parsing lab.cd from the evaluated lab")?;
                let strategy = cd.strategy.tag();

                println!("  {} lab: {}", style("✓").green(), lab_name);
                println!("  {} strategy: {}", style("✓").green(), strategy);
                println!(
                    "  {} clusters: {}",
                    style("✓").green(),
                    cluster_names.join(", ")
                );

                for cluster in &cluster_names {
                    match crate::io::nix::get_cluster_config_from_lab(&lab, cluster) {
                        Ok(config) => {
                            let provisioner = config["provisioner"].as_str().unwrap_or("unknown");
                            let floe_count = config["floes"]
                                .as_object()
                                .map(|c| {
                                    c.values()
                                        .filter(|v| {
                                            v.get("enable")
                                                .and_then(|e| e.as_bool())
                                                .unwrap_or(false)
                                        })
                                        .count()
                                })
                                .unwrap_or(0);
                            println!(
                                "    {} {} ({}, {} floes)",
                                style("✓").green(),
                                cluster,
                                provisioner,
                                floe_count,
                            );
                        }
                        Err(e) => {
                            println!("    {} {}: {}", style("✗").red(), cluster, e,);
                        }
                    }
                }
            }
            Err(e) => {
                println!("  {} lab config failed: {}", style("✗").red(), e);
                bail!("Configuration validation failed");
            }
        }
        println!();
    }

    println!("{} Manifests", style("catallaxy").cyan().bold());
    let package_path = match path {
        Some(p) => p,
        None => {
            let lab_name =
                lab_name.expect("lab_name is Some whenever path is None (see binding above)");
            println!("  Building...");
            let store_path = crate::io::nix::build_lab_package(ctx, &lab_name)?;
            PathBuf::from(store_path)
        }
    };

    let passed = lint::run_lint(&package_path, &skip)?;

    if !passed {
        bail!("lint checks failed");
    }

    Ok(())
}

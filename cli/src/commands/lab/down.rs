use anyhow::Result;
use console::style;

use crate::config::Context as CataContext;

pub fn run(ctx: &CataContext, name: &str) -> Result<()> {
    println!(
        "{} Stopping lab '{name}' (use 'lab destroy' to delete everything)",
        style("catallaxy").cyan().bold()
    );

    let lab = crate::io::nix::get_lab_config(ctx, name)?;

    let cluster_names: Vec<String> = lab["clusterNames"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();

    if !cluster_names.is_empty() {
        println!();
        println!("{}", style("Clusters:").bold());

        for cluster_name in &cluster_names {
            match crate::io::nix::get_cluster_spec_from_lab(&lab, cluster_name) {
                Ok(spec) => {
                    println!(
                        "{} Stopping cluster '{cluster_name}'...",
                        style(">>>").cyan()
                    );
                    if let Err(e) = crate::provision::stop_cluster(ctx, cluster_name, &spec) {
                        println!(
                            "{} Failed to stop '{}': {}",
                            style("Warning:").yellow(),
                            cluster_name,
                            e
                        );
                    }
                }
                Err(e) => {
                    println!(
                        "{} Failed to load config for '{}': {}",
                        style("Warning:").yellow(),
                        cluster_name,
                        e
                    );
                }
            }
        }
    }

    println!();
    println!(
        "{} Lab '{name}': clusters stopped. Run 'lab up' to resume.",
        style("catallaxy").cyan().bold()
    );

    let running: Vec<String> = lab["services"]
        .as_object()
        .map(|svcs| {
            svcs.iter()
                .filter(|(_, svc)| {
                    svc["container"]
                        .as_str()
                        .is_some_and(crate::io::docker::container_running)
                })
                .map(|(svc_name, _)| svc_name.clone())
                .collect()
        })
        .unwrap_or_default();

    if !running.is_empty() {
        println!(
            "{} Host services are still running and still holding their ports: {}.\n    \
             `lab down` stops clusters only. Another lab's `lab up` will refuse to \
             start while these hold the same ports; `lab destroy` removes them.",
            style(">>>").yellow(),
            running.join(", "),
        );
    }

    Ok(())
}

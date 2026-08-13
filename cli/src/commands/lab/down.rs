use anyhow::Result;
use console::style;

use crate::config::Context as CataContext;

pub async fn run(ctx: &CataContext, name: &str) -> Result<()> {
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
        "{} Lab '{name}' is stopped. Run 'lab up' to resume.",
        style("catallaxy").cyan().bold()
    );

    Ok(())
}

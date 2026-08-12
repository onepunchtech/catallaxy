use anyhow::Result;
use console::style;

use crate::config::Context as CataContext;

pub async fn run(
    ctx: &CataContext,
    name: &str,
    bundle: Option<String>,
    dry_run: bool,
    force: bool,
) -> Result<()> {
    let lab = crate::io::nix::get_lab_config(ctx, name)?;

    println!("{} Applying lab '{name}'", style("catallaxy").cyan().bold());

    let secrets_cache = crate::commands::secrets::load_secrets_cache(
        ctx,
        name,
        &lab,
        "Loading secret stores (cached for the rest of the run)...",
    )?;

    println!("{} Building lab manifests...", style(">>>").cyan());
    let lab_package = crate::io::nix::build_lab_package(ctx, name)?;

    let cluster_names: Vec<String> = lab["clusterNames"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();

    for cluster_name in &cluster_names {
        let cluster_manifests = format!("{lab_package}/manifests/{cluster_name}");
        crate::commands::apply::run(
            ctx,
            crate::commands::apply::ApplyArgs {
                cluster: Some(cluster_name.to_string()),
                bundle: bundle.clone(),
                dry_run,
                force,
                manifests_dir: Some(cluster_manifests),
                secrets_cache: secrets_cache.clone(),
                lab_config: Some(lab.clone()),
                kube_context_override: None,
            },
        )
        .await?;
    }

    Ok(())
}

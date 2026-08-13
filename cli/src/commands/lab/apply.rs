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
    let lab = crate::io::nix::get_lab_spec(ctx, name)?;

    println!("{} Applying lab '{name}'", style("catallaxy").cyan().bold());

    let secrets_cache = crate::io::secrets::load_secrets_cache(
        ctx,
        name,
        &lab.secrets,
        "Loading secret stores (cached for the rest of the run)...",
    )?;

    println!("{} Building lab manifests...", style(">>>").cyan());
    let lab_package = crate::io::nix::build_lab_package(ctx, name)?;

    for cluster_name in &lab.cluster_names {
        let cluster_manifests = format!("{lab_package}/manifests/{cluster_name}");
        crate::apply::apply(
            ctx,
            crate::apply::ApplyRequest {
                bundle: bundle.as_deref(),
                dry_run,
                force,
                manifests_dir: Some(&cluster_manifests),
                secrets_cache: secrets_cache.clone(),
                lab: Some(&lab),
                ..crate::apply::ApplyRequest::for_cluster(cluster_name)
            },
        )
        .await?;
    }

    Ok(())
}

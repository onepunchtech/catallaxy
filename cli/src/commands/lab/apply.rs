use anyhow::{Result, bail};
use console::style;

use crate::config::Context as CataContext;
use crate::domain::LabSpec;

pub async fn run(
    ctx: &CataContext,
    name: &str,
    bundle: Option<String>,
    cluster: Option<String>,
    dry_run: bool,
    force: bool,
) -> Result<()> {
    let lab = crate::io::nix::get_lab_spec(ctx, name)?;
    let targets = targets_in(&lab, cluster.as_deref())?;

    println!("{} Applying lab '{name}'", style("catallaxy").cyan().bold());

    let secrets_cache = crate::io::secrets::load_secrets_cache(
        ctx,
        name,
        &lab.secrets,
        "Loading secret stores (cached for the rest of the run)...",
    )?;

    println!("{} Building lab manifests...", style(">>>").cyan());
    let lab_package = crate::io::nix::build_lab_package(ctx, name)?;

    for cluster_name in &targets {
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

pub async fn diff(
    ctx: &CataContext,
    name: &str,
    bundle: Option<String>,
    cluster: Option<String>,
) -> Result<()> {
    let lab = crate::io::nix::get_lab_spec(ctx, name)?;
    let targets = targets_in(&lab, cluster.as_deref())?;

    println!("{} Building lab manifests...", style(">>>").cyan());
    let lab_package = crate::io::nix::build_lab_package(ctx, name)?;

    let mut any_changed = false;
    for cluster_name in &targets {
        let cluster_manifests = format!("{lab_package}/manifests/{cluster_name}");
        any_changed |= crate::apply::diff(
            ctx,
            crate::apply::ApplyRequest {
                bundle: bundle.as_deref(),
                manifests_dir: Some(&cluster_manifests),
                lab: Some(&lab),
                ..crate::apply::ApplyRequest::for_cluster(cluster_name)
            },
        )
        .await?;
    }

    if any_changed {
        std::process::exit(3);
    }
    Ok(())
}

fn targets_in(lab: &LabSpec, cluster: Option<&str>) -> Result<Vec<String>> {
    match cluster {
        None => Ok(lab.cluster_names.clone()),
        Some(name) if lab.cluster_names.iter().any(|c| c == name) => Ok(vec![name.to_string()]),
        Some(name) => bail!(
            "lab '{}' has no cluster '{name}'. Available: {}",
            lab.lab_name,
            lab.cluster_names.join(", "),
        ),
    }
}

use std::path::{Path, PathBuf};

use anyhow::Result;
use console::style;

use crate::io;
use crate::plan::StepContext;

pub async fn run(
    sctx: &StepContext<'_>,
    target: &str,
    bootstrap: bool,
    kube_context_override: Option<&str>,
) -> Result<()> {
    let subdir = if bootstrap {
        "stage1"
    } else if sctx.strategy == "kapp" {
        "manifests"
    } else {
        "bootstrap"
    };
    let cluster_manifests = format!("{}/{subdir}/{target}", sctx.lab_package);

    if !Path::new(&cluster_manifests).exists() {
        println!(
            "{} No manifests for '{}', skipping",
            style(">>>").yellow(),
            target
        );
        return Ok(());
    }

    if sctx.bootstrap == "kubectl-ssa" {
        let kube_context = kube_context_override.map(String::from).unwrap_or_else(|| {
            crate::commands::lab::state::resolve_cluster_context(sctx.lab, target)
        });
        let cluster_config = crate::io::nix::get_cluster_config_with_secrets(sctx.lab, target).ok();
        return io::ssa::apply_manifest_root(
            sctx.ctx,
            &kube_context,
            &PathBuf::from(&cluster_manifests),
            "catallaxy-bootstrap",
            600,
            sctx.dry_run,
            cluster_config.as_ref(),
            sctx.secrets_cache.as_ref(),
        );
    }

    crate::commands::lab::orchestrate::apply_cluster_components(
        sctx.ctx,
        target,
        sctx.dry_run,
        true,
        Some(cluster_manifests),
        sctx.secrets_cache.clone(),
        Some(sctx.lab),
        kube_context_override.map(String::from),
    )
    .await
}

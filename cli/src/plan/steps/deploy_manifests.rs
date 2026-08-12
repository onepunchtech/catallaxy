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
            io::ssa::ApplyManifests {
                kube_context: &kube_context,
                manifest_root: &PathBuf::from(&cluster_manifests),
                field_manager: "catallaxy-bootstrap",
                wait_timeout_seconds: 600,
                dry_run: sctx.dry_run,
                lab_config: cluster_config.as_ref(),
                secrets_cache: sctx.secrets_cache.as_ref(),
            },
        );
    }

    crate::commands::lab::orchestrate::apply_cluster_components(
        sctx.ctx,
        crate::commands::lab::orchestrate::ClusterComponents {
            cluster_name: target,
            dry_run: sctx.dry_run,
            force: true,
            manifests_dir: Some(cluster_manifests),
            secrets_cache: sctx.secrets_cache.clone(),
            lab_config: Some(sctx.lab),
            kube_context_override: kube_context_override.map(String::from),
        },
    )
    .await
}

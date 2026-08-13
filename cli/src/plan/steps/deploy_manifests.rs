use std::path::{Path, PathBuf};

use anyhow::Result;
use console::style;

use crate::domain::{BootstrapTool, DeployStrategy};
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
    } else if sctx.strategy == DeployStrategy::Kapp {
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

    if sctx.bootstrap == BootstrapTool::KubectlSsa {
        let kube_context = match kube_context_override {
            Some(override_) => override_.to_string(),
            None => sctx.lab.kube_context(target)?.to_string(),
        };
        return io::ssa::apply_manifest_root(
            sctx.ctx,
            io::ssa::ApplyManifests {
                kube_context: &kube_context,
                manifest_root: &PathBuf::from(&cluster_manifests),
                field_manager: "catallaxy-bootstrap",
                wait_timeout_seconds: 600,
                dry_run: sctx.dry_run,
                cluster: sctx.lab.cluster(target).ok(),
                lab_name: sctx.lab_name,
                secrets_spec: &sctx.lab.secrets,
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

use std::path::{Path, PathBuf};

use anyhow::Result;
use console::style;

use crate::domain::plan::DeployManifestsParams;
use crate::domain::{BootstrapTool, DeployStrategy};
use crate::io;
use crate::plan::StepContext;

pub async fn run(sctx: &StepContext<'_>, p: &DeployManifestsParams) -> Result<()> {
    let DeployManifestsParams {
        target,
        bootstrap,
        kube_context: kube_context_override,
    } = p;
    let kube_context_override = kube_context_override.as_deref();

    let subdir = if *bootstrap {
        "stage1"
    } else if sctx.strategy == DeployStrategy::Kapp {
        "manifests"
    } else {
        "bootstrap"
    };
    let cluster_manifests = format!("{}/{subdir}/{target}", sctx.lab_package);

    if !Path::new(&cluster_manifests).exists() {
        anyhow::bail!(
            "the deploy step for '{target}' found nothing at {cluster_manifests}.\n\
             The lab package has no '{subdir}' tree for this cluster, which means the \
             deploy strategy and what the package actually built disagree. Deploying \
             nothing and reporting success would leave the cluster empty and green."
        );
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

    println!(
        "{} Applying manifests to cluster '{}'...",
        style(">>>").cyan(),
        target
    );

    crate::apply::apply(
        sctx.ctx,
        crate::apply::ApplyRequest {
            dry_run: sctx.dry_run,
            force: true,
            manifests_dir: Some(&cluster_manifests),
            secrets_cache: sctx.secrets_cache.clone(),
            lab: Some(sctx.lab),
            kube_context_override,
            ..crate::apply::ApplyRequest::for_cluster(target)
        },
    )
    .await
}

use std::path::{Path, PathBuf};

use anyhow::{Result, bail};
use console::style;

use crate::domain::BootstrapTool;
use crate::io;
use crate::plan::StepContext;

pub async fn run(
    sctx: &StepContext<'_>,
    cluster: &str,
    bootstrap_ctx: &str,
    target_ctx: &str,
    provisioner: &str,
) -> Result<()> {
    let cluster_manifests = format!("{}/stage1/{cluster}", sctx.lab_package);

    if !sctx.dry_run && io::kubectl::api_reachable(target_ctx) {
        println!(
            "{} Skipping pivot: cloud cluster '{}' is already reachable",
            style(">>>").green(),
            cluster
        );
        if Path::new(&cluster_manifests).exists() {
            apply_stage1_to_target(sctx, cluster, &cluster_manifests, target_ctx).await?;
        }
        cleanup_leftover_bootstrap(sctx, cluster, bootstrap_ctx)?;
        return Ok(());
    }

    println!(
        "{} Pivoting '{}': {} → {}",
        style(">>>").cyan(),
        cluster,
        style(bootstrap_ctx).dim(),
        style(target_ctx).bold(),
    );

    if Path::new(&cluster_manifests).exists() {
        if !sctx.dry_run && !io::kubectl::api_reachable(target_ctx) {
            bail!(
                "target context '{target_ctx}' not reachable; \
                 sync-kubeconfig must run first (kubeconfig sync failed?)"
            );
        }
        println!(
            "{} Deploying stage1 manifests to cloud '{}'...",
            style(">>>").cyan(),
            cluster
        );
        apply_stage1_to_target(sctx, cluster, &cluster_manifests, target_ctx).await?;
    }

    if sctx.dry_run {
        println!(
            "{} Would migrate {} state and destroy bootstrap",
            style(">>>").yellow(),
            provisioner
        );
        return Ok(());
    }

    migrate_provisioner_state(cluster, bootstrap_ctx, target_ctx, provisioner)?;

    println!(
        "{} Destroying bootstrap cluster '{}'...",
        style(">>>").cyan(),
        cluster,
    );
    let bootstrap_spec = sctx.lab.cluster(cluster)?;
    crate::provision::deprovision_cluster(sctx.ctx, cluster, bootstrap_spec)?;

    println!(
        "{} Pivot complete: '{}' is now running in the cloud",
        style(">>>").green(),
        cluster,
    );
    Ok(())
}

async fn apply_stage1_to_target(
    sctx: &StepContext<'_>,
    cluster: &str,
    cluster_manifests: &str,
    target_ctx: &str,
) -> Result<()> {
    if sctx.bootstrap == BootstrapTool::KubectlSsa {
        return io::ssa::apply_manifest_root(
            sctx.ctx,
            io::ssa::ApplyManifests {
                kube_context: target_ctx,
                manifest_root: &PathBuf::from(cluster_manifests),
                field_manager: "catallaxy-bootstrap",
                wait_timeout_seconds: 600,
                dry_run: sctx.dry_run,
                cluster: sctx.lab.cluster(cluster).ok(),
                lab_name: sctx.lab_name,
                secrets_spec: &sctx.lab.secrets,
                secrets_cache: sctx.secrets_cache.as_ref(),
            },
        );
    }
    println!(
        "{} Applying manifests to cluster '{}'...",
        style(">>>").cyan(),
        cluster
    );

    crate::apply::apply(
        sctx.ctx,
        crate::apply::ApplyRequest {
            dry_run: sctx.dry_run,
            force: true,
            manifests_dir: Some(cluster_manifests),
            secrets_cache: sctx.secrets_cache.clone(),
            lab: Some(sctx.lab),
            kube_context_override: Some(target_ctx),
            ..crate::apply::ApplyRequest::for_cluster(cluster)
        },
    )
    .await
}

fn migrate_provisioner_state(
    cluster: &str,
    bootstrap_ctx: &str,
    target_ctx: &str,
    provisioner: &str,
) -> Result<()> {
    match provisioner {
        "crossplane" => {
            println!(
                "{} Waiting for Crossplane to be healthy on '{cluster}'...",
                style(">>>").cyan(),
            );
            io::kubectl::wait_crossplane_healthy(target_ctx)?;

            println!(
                "{} Copying external-name annotations from bootstrap to '{cluster}'...",
                style(">>>").cyan(),
            );
            io::kubectl::copy_external_names(bootstrap_ctx, target_ctx)?;

            println!(
                "{} Waiting for managed resources on '{cluster}'...",
                style(">>>").cyan(),
            );
            io::kubectl::wait_managed_ready(target_ctx, 600)?;

            println!(
                "{} Orphaning managed resources on bootstrap...",
                style(">>>").cyan(),
            );
            io::kubectl::orphan_managed_resources(bootstrap_ctx)?;
        }
        "capi" => {
            println!(
                "{} CAPI pivot: using clusterctl move...",
                style(">>>").cyan(),
            );
            let status = std::process::Command::new("clusterctl")
                .args([
                    "move",
                    "--to-kubeconfig-context",
                    target_ctx,
                    "--kubeconfig-context",
                    bootstrap_ctx,
                ])
                .status();
            if let Ok(s) = status
                && !s.success()
            {
                bail!("clusterctl move failed");
            }
        }
        other => {
            println!(
                "{} Unknown provisioner '{other}' for pivot",
                style("Warning:").yellow(),
            );
        }
    }
    Ok(())
}

fn cleanup_leftover_bootstrap(
    sctx: &StepContext<'_>,
    cluster: &str,
    bootstrap_ctx: &str,
) -> Result<()> {
    if sctx.dry_run || !io::kubectl::api_reachable(bootstrap_ctx) {
        return Ok(());
    }
    println!(
        "{} Cleaning up leftover bootstrap cluster '{bootstrap_ctx}'...",
        style(">>>").cyan(),
    );
    let bootstrap_spec = sctx.lab.cluster(cluster)?;
    if let Err(e) = crate::provision::deprovision_cluster(sctx.ctx, cluster, bootstrap_spec) {
        println!(
            "{} Failed to clean up bootstrap cluster '{bootstrap_ctx}': {e}",
            style("Warning:").yellow(),
        );
    }
    Ok(())
}

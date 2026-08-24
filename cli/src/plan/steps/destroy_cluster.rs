use anyhow::Result;
use console::style;

use crate::domain::plan::DestroyClusterParams;
use crate::domain::{ClusterSpec, ProvisionerKind, StepFailure};
use crate::io;
use crate::plan::StepContext;

pub fn run(sctx: &StepContext<'_>, p: &DestroyClusterParams) -> Result<()> {
    let DestroyClusterParams {
        name: cluster_name,
        provisioner: _,
        skip_if_missing,
    } = p;
    let skip_if_missing = skip_if_missing.unwrap_or(false);

    let mut step_failed = false;

    match sctx.lab.cluster(cluster_name) {
        Ok(spec) => {
            if skip_if_missing && k3d_already_gone(sctx, spec) {
                return Ok(());
            }
            if let Err(e) = crate::provision::deprovision_cluster(sctx.ctx, cluster_name, spec) {
                step_failed = true;
                println!(
                    "{} Failed to destroy '{}': {}",
                    style("ERROR").red(),
                    cluster_name,
                    e,
                );
            }
            if spec.provisioner == ProvisionerKind::K3d
                && !io::k3d::sweep_stragglers(spec.provisioner_config.k3d.cluster_name.as_str())
            {
                step_failed = true;
            }
        }
        Err(e) => {
            step_failed = true;
            println!(
                "{} Failed to load config for '{}': {}",
                style("ERROR").red(),
                cluster_name,
                e,
            );
        }
    }

    if let Err(e) = crate::io::kubectl::cleanup_kubeconfig(cluster_name) {
        println!(
            "{} Failed to cleanup kubeconfig for '{}': {}",
            style("Warning:").yellow(),
            cluster_name,
            e,
        );
    }

    if step_failed {
        sctx.failures.borrow_mut().push(StepFailure::new(
            "destroy-cluster",
            format!("'{cluster_name}' was not confirmed destroyed"),
        ));
    }
    Ok(())
}

fn k3d_already_gone(sctx: &StepContext<'_>, spec: &ClusterSpec) -> bool {
    if spec.provisioner != ProvisionerKind::K3d {
        return false;
    }
    let cluster_short = spec.provisioner_config.k3d.cluster_name.as_str();
    let docker_host = crate::provision::resolve_docker_host(sctx.ctx, spec)
        .ok()
        .flatten();
    if io::k3d::cluster_exists(cluster_short, docker_host.as_deref()) {
        return false;
    }
    println!(
        "{} k3d cluster '{}' already gone; skipping",
        style(">>>").green(),
        cluster_short
    );
    true
}

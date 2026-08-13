use std::process::Command;

use anyhow::Result;
use console::style;

use crate::domain::plan::DestroyClusterParams;
use crate::domain::{ClusterSpec, ProvisionerKind};
use crate::io;
use crate::plan::StepContext;

pub async fn run(sctx: &StepContext<'_>, p: &DestroyClusterParams) -> Result<()> {
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

    if !verify_no_stragglers(sctx.lab_name, cluster_name) {
        step_failed = true;
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
        sctx.failures
            .borrow_mut()
            .push(format!("destroy-cluster {cluster_name}"));
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

fn verify_no_stragglers(lab_name: &str, cluster_name: &str) -> bool {
    let container_prefix = format!("k3d-{lab_name}-{cluster_name}-");
    let out = match Command::new("docker")
        .args([
            "ps",
            "-a",
            "--format",
            "{{.Names}}",
            "--filter",
            &format!("name={container_prefix}"),
        ])
        .output()
    {
        Ok(o) if o.status.success() => o,
        Ok(o) => {
            println!(
                "{} `docker ps` failed (exit {:?}): {}",
                style("ERROR").red(),
                o.status.code(),
                String::from_utf8_lossy(&o.stderr),
            );
            return false;
        }
        Err(e) => {
            println!(
                "{} could not run `docker ps` to verify destroy: {e}",
                style("ERROR").red(),
            );
            return false;
        }
    };

    let stragglers: Vec<&str> = std::str::from_utf8(&out.stdout)
        .unwrap_or("")
        .lines()
        .filter(|l| !l.is_empty())
        .collect();
    if stragglers.is_empty() {
        return true;
    }
    println!(
        "{} '{}' left {} container(s) behind: {}",
        style("ERROR").red(),
        cluster_name,
        stragglers.len(),
        stragglers.join(", "),
    );
    for c in &stragglers {
        println!("{} docker rm -f {c}", style(">>>").yellow());
        let _ = Command::new("docker").args(["rm", "-f", c]).status();
    }
    false
}

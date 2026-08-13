use std::process::Command;

use anyhow::Result;
use console::style;

use crate::io::process::{run_capture, run_streaming};

pub struct ProviderSpec {
    pub bootstrap: Vec<String>,
    pub control_plane: Vec<String>,
    pub infrastructure: Vec<String>,
}

pub fn init(kube_context: &str, providers: &ProviderSpec) -> Result<()> {
    println!("{} Initializing Cluster API...", style(">>>").cyan());

    let mut cmd = Command::new("clusterctl");
    cmd.env("KUBECONFIG_CONTEXT", kube_context);
    cmd.args(["init"]);

    for bp in &providers.bootstrap {
        cmd.args(["--bootstrap", bp]);
    }
    for cp in &providers.control_plane {
        cmd.args(["--control-plane", cp]);
    }
    for ip in &providers.infrastructure {
        cmd.args(["--infrastructure", ip]);
    }

    run_streaming(&mut cmd)?;

    println!("{} Cluster API initialized", style(">>>").green());
    Ok(())
}

pub fn move_resources(from_context: &str, to_context: &str, namespace: &str) -> Result<()> {
    println!(
        "{} Moving CAPI resources from {} to {}...",
        style(">>>").cyan(),
        from_context,
        to_context
    );

    let mut cmd = Command::new("clusterctl");
    cmd.args([
        "move",
        "--kubeconfig-context",
        from_context,
        "--to-kubeconfig-context",
        to_context,
        "--namespace",
        namespace,
    ]);

    run_streaming(&mut cmd)?;

    println!("{} CAPI resources moved successfully", style(">>>").green());
    Ok(())
}

pub fn get_kubeconfig(kube_context: &str, cluster_name: &str, namespace: &str) -> Result<String> {
    println!(
        "{} Getting kubeconfig for cluster '{cluster_name}'...",
        style(">>>").cyan()
    );

    let mut cmd = Command::new("clusterctl");
    cmd.args([
        "get",
        "kubeconfig",
        cluster_name,
        "--kubeconfig-context",
        kube_context,
        "--namespace",
        namespace,
    ]);

    run_capture(&mut cmd)
}

pub fn wait_control_plane_initialized(
    kube_context: &str,
    cluster_name: &str,
    namespace: &str,
    timeout: &str,
) -> Result<()> {
    println!(
        "{} Waiting for control plane to be initialized...",
        style(">>>").cyan()
    );

    let mut cmd = Command::new("kubectl");
    cmd.args([
        "--context",
        kube_context,
        "wait",
        "--for=condition=ControlPlaneInitialized",
        &format!("cluster/{cluster_name}"),
        "-n",
        namespace,
        &format!("--timeout={timeout}"),
    ]);

    run_streaming(&mut cmd)?;

    println!("{} Control plane initialized", style(">>>").green());
    Ok(())
}

use std::process::Command;

use anyhow::Result;
use console::style;

use crate::config::Context as CataContext;
use crate::io::process::{run_capture, run_streaming};

pub struct ProviderSpec {
    pub bootstrap: Vec<String>,
    pub control_plane: Vec<String>,
    pub infrastructure: Vec<String>,
}

pub fn init(ctx: &CataContext, kube_context: &str, providers: &ProviderSpec) -> Result<()> {
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

    run_streaming(&mut cmd, ctx)?;

    println!("{} Cluster API initialized", style(">>>").green());
    Ok(())
}

pub fn move_resources(
    ctx: &CataContext,
    from_context: &str,
    to_context: &str,
    namespace: &str,
) -> Result<()> {
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

    run_streaming(&mut cmd, ctx)?;

    println!("{} CAPI resources moved successfully", style(">>>").green());
    Ok(())
}

pub fn get_kubeconfig(
    ctx: &CataContext,
    kube_context: &str,
    cluster_name: &str,
    namespace: &str,
) -> Result<String> {
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

    run_capture(&mut cmd, ctx)
}

pub fn wait_cluster_ready(
    ctx: &CataContext,
    kube_context: &str,
    cluster_name: &str,
    namespace: &str,
    timeout: &str,
) -> Result<()> {
    println!(
        "{} Waiting for cluster '{}' to be ready...",
        style(">>>").cyan(),
        cluster_name
    );

    let mut cmd = Command::new("kubectl");
    cmd.args([
        "--context",
        kube_context,
        "wait",
        "--for=condition=Ready",
        &format!("cluster/{cluster_name}"),
        "-n",
        namespace,
        &format!("--timeout={timeout}"),
    ]);

    run_streaming(&mut cmd, ctx)?;

    println!(
        "{} Cluster '{}' is ready",
        style(">>>").green(),
        cluster_name
    );
    Ok(())
}

pub fn wait_control_plane_initialized(
    ctx: &CataContext,
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

    run_streaming(&mut cmd, ctx)?;

    println!("{} Control plane initialized", style(">>>").green());
    Ok(())
}

pub fn is_cluster_ready(kube_context: &str, cluster_name: &str, namespace: &str) -> bool {
    use std::process::Stdio;
    let output = Command::new("kubectl")
        .args([
            "--context",
            kube_context,
            "get",
            "cluster",
            cluster_name,
            "-n",
            namespace,
            "-o",
            "jsonpath={.status.conditions[?(@.type==\"Ready\")].status}",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output();

    match output {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim() == "True",
        _ => false,
    }
}

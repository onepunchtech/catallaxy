use std::process::Command;

use anyhow::Result;
use console::style;

use crate::config::Context as CataContext;
use crate::io::process::run_streaming;

pub fn cluster_create(
    ctx: &CataContext,
    name: &str,
    _control_planes: u32,
    workers: u32,
    docker_host: Option<&str>,
) -> Result<()> {
    println!("{} Creating Talos cluster '{name}'...", style(">>>").cyan());

    let mut cmd = Command::new("talosctl");
    cmd.args([
        "cluster",
        "create",
        "docker",
        "--name",
        name,
        "--workers",
        &workers.to_string(),
    ]);

    if let Some(host) = docker_host {
        cmd.env("DOCKER_HOST", host);
    }

    run_streaming(&mut cmd, ctx)?;

    println!(
        "{} Cluster created. Kubeconfig merged into ~/.kube/config",
        style(">>>").green()
    );
    Ok(())
}

pub fn cluster_destroy(ctx: &CataContext, name: &str, docker_host: Option<&str>) -> Result<()> {
    println!(
        "{} Destroying Talos cluster '{name}'...",
        style(">>>").cyan()
    );

    let mut cmd = Command::new("talosctl");
    cmd.args(["cluster", "destroy", "--name", name]);

    if let Some(host) = docker_host {
        cmd.env("DOCKER_HOST", host);
    }

    run_streaming(&mut cmd, ctx)?;

    println!("{} Cluster destroyed", style(">>>").green());
    Ok(())
}

pub fn cluster_exists(name: &str, _docker_host: Option<&str>) -> bool {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let state_file = format!("{home}/.talos/clusters/{name}/state.yaml");
    std::path::Path::new(&state_file).exists()
}

pub fn cluster_show(ctx: &CataContext, name: &str, docker_host: Option<&str>) -> Result<()> {
    let mut cmd = Command::new("talosctl");
    cmd.args(["cluster", "show", "--name", name]);

    if let Some(host) = docker_host {
        cmd.env("DOCKER_HOST", host);
    }

    run_streaming(&mut cmd, ctx)
}

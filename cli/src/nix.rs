//! Nix evaluation and build helpers

use std::process::{Command, Stdio};

use anyhow::{Context, Result, bail};
use serde::de::DeserializeOwned;

use crate::config::Context as CataContext;

/// Run a nix command, streaming stderr to the terminal in real-time.
/// Returns stdout on success, or errors with exit status on failure.
fn run_nix(args: &[&str]) -> Result<String> {
    let child = Command::new("nix")
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit()) // show nix progress to user
        .spawn()
        .context("Failed to spawn nix")?;

    let output = child.wait_with_output().context("Failed to wait for nix")?;

    if !output.status.success() {
        bail!("nix {} failed (exit {})", args[0], output.status);
    }

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

/// Evaluate a flake attribute and return parsed JSON
pub fn eval_flake<T: DeserializeOwned>(ctx: &CataContext, attr: &str) -> Result<T> {
    let uri = ctx.flake_uri();
    let installable = format!("{uri}#{attr}");

    let stdout = run_nix(&["eval", "--json", &installable])?;
    serde_json::from_str(&stdout).context("Failed to parse nix eval output")
}

/// Build a flake output and return the store path
pub fn build(ctx: &CataContext, attr: &str) -> Result<String> {
    let uri = ctx.flake_uri();
    let installable = format!("{uri}#{attr}");

    let stdout = run_nix(&["build", "--no-link", "--print-out-paths", &installable])?;
    Ok(stdout.trim().to_string())
}

/// Get the cluster configuration as JSON from the lab config.
/// Requires lab config to be passed in (avoids separate nix eval per cluster).
pub fn get_cluster_config_from_lab(
    lab: &serde_json::Value,
    cluster_name: &str,
) -> Result<serde_json::Value> {
    lab.pointer(&format!("/clusters/{cluster_name}"))
        .cloned()
        .ok_or_else(|| {
            let available: Vec<&str> = lab
                .pointer("/clusters")
                .and_then(|v| v.as_object())
                .map(|m| m.keys().map(|k| k.as_str()).collect())
                .unwrap_or_default();
            anyhow::anyhow!(
                "cluster '{}' not found in lab (available: {})",
                cluster_name,
                available.join(", ")
            )
        })
}

/// Get the cluster configuration as JSON from flake output (legacy, for non-lab contexts)
pub fn get_cluster_config(ctx: &CataContext, cluster_name: &str) -> Result<serde_json::Value> {
    let system = current_system();
    eval_flake(ctx, &format!("clusters.{system}.{cluster_name}"))
}

/// List available cluster names from the flake
pub fn list_clusters(ctx: &CataContext) -> Result<Vec<String>> {
    let uri = ctx.flake_uri();
    let system = current_system();
    let installable = format!("{uri}#clusters.{system}");

    let stdout = run_nix(&[
        "eval",
        "--json",
        &installable,
        "--apply",
        "builtins.attrNames",
    ])?;
    serde_json::from_str(&stdout).context("Failed to parse cluster list")
}

/// Get the current nix system string (e.g., "aarch64-darwin", "x86_64-linux")
pub fn current_system() -> String {
    let arch = std::env::consts::ARCH;
    let os = std::env::consts::OS;

    let nix_arch = match arch {
        "aarch64" => "aarch64",
        "x86_64" => "x86_64",
        _ => arch,
    };
    let nix_os = match os {
        "macos" => "darwin",
        "linux" => "linux",
        _ => os,
    };

    format!("{nix_arch}-{nix_os}")
}

/// Get a lab configuration as JSON from flake output
pub fn get_lab_config(ctx: &CataContext, lab_name: &str) -> Result<serde_json::Value> {
    let system = current_system();
    // Quote lab name to handle dotted names like "homelab.local"
    eval_flake(ctx, &format!("labs.{system}.\"{lab_name}\""))
}

/// List available lab names from the flake
pub fn list_labs(ctx: &CataContext) -> Result<Vec<String>> {
    let uri = ctx.flake_uri();
    let system = current_system();
    let installable = format!("{uri}#labs.{system}");

    let stdout = run_nix(&[
        "eval",
        "--json",
        &installable,
        "--apply",
        "builtins.attrNames",
    ])?;
    serde_json::from_str(&stdout).context("Failed to parse lab list")
}

/// Build rendered manifests for a cluster and return the output path
pub fn build_manifests(ctx: &CataContext, cluster_name: &str) -> Result<String> {
    let system = current_system();
    build(ctx, &format!("manifests.{system}.{cluster_name}"))
}

/// Build a lab's output package and return the store path
pub fn build_lab_package(ctx: &CataContext, lab_name: &str) -> Result<String> {
    let system = current_system();
    build(ctx, &format!("labPackages.{system}.\"{lab_name}\""))
}

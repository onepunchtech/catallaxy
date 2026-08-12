use std::collections::HashMap;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{Mutex, OnceLock};

use anyhow::{Context, Result};
use console::style;
use serde::de::DeserializeOwned;

use crate::config::Context as CataContext;
use crate::domain::{ClusterSpec, LabSpec};
use crate::error::{CataError, CataResult};

fn lab_config_cache() -> &'static Mutex<HashMap<String, serde_json::Value>> {
    static CACHE: OnceLock<Mutex<HashMap<String, serde_json::Value>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn refresh_path_inputs(flake_uri: &str) {
    static GUARD: OnceLock<()> = OnceLock::new();
    if GUARD.set(()).is_err() {
        return;
    }

    let dir_str = flake_uri.strip_prefix("path:").unwrap_or(flake_uri);
    let lock_path = Path::new(dir_str).join("flake.lock");
    let lock_str = match std::fs::read_to_string(&lock_path) {
        Ok(s) => s,
        Err(_) => return,
    };
    let lock: serde_json::Value = match serde_json::from_str(&lock_str) {
        Ok(v) => v,
        Err(_) => return,
    };
    let Some(nodes) = lock["nodes"].as_object() else {
        return;
    };

    for (input_name, node) in nodes {
        if input_name == "root" {
            continue;
        }
        let Some(locked) = node["locked"].as_object() else {
            continue;
        };
        let is_path = locked.get("type").and_then(|v| v.as_str()) == Some("path");
        if !is_path {
            continue;
        }
        let path = locked.get("path").and_then(|v| v.as_str()).unwrap_or("");
        if path.is_empty() || !Path::new(path).exists() {
            continue;
        }
        eprintln!(
            "{} Refreshing path flake input '{}' ({})...",
            style(">>>").dim(),
            input_name,
            path,
        );
        let out = Command::new("nix")
            .args(["flake", "update", input_name, "--refresh"])
            .current_dir(dir_str)
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .output();
        match out {
            Ok(o) if !o.status.success() => {
                eprintln!(
                    "{} Could not refresh '{}'. Continuing with the existing lock, which may be stale.\n{}",
                    style("Warning:").yellow(),
                    input_name,
                    String::from_utf8_lossy(&o.stderr).trim(),
                );
            }
            Err(e) => {
                eprintln!(
                    "{} Could not run `nix flake update {}`: {e}. Continuing with the existing lock, which may be stale.",
                    style("Warning:").yellow(),
                    input_name,
                );
            }
            _ => {}
        }
    }
}

fn run_nix(args: &[&str]) -> CataResult<String> {
    let child = Command::new("nix")
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(|e| CataError::NixEval(format!("failed to spawn nix: {e}")))?;

    let output = child
        .wait_with_output()
        .map_err(|e| CataError::NixEval(format!("failed to wait for nix: {e}")))?;

    if !output.status.success() {
        return Err(CataError::NixEval(format!(
            "nix {} failed (exit {})",
            args[0], output.status
        )));
    }

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

pub fn eval_flake<T: DeserializeOwned>(ctx: &CataContext, attr: &str) -> Result<T> {
    let uri = ctx.flake_uri();
    let installable = format!("{uri}#{attr}");

    let stdout = run_nix(&["eval", "--json", &installable])?;
    serde_json::from_str(&stdout).context("Failed to parse nix eval output")
}

pub fn build(ctx: &CataContext, attr: &str) -> CataResult<String> {
    let uri = ctx.flake_uri();
    let installable = format!("{uri}#{attr}");

    let stdout = run_nix(&["build", "--no-link", "--print-out-paths", &installable])?;
    Ok(stdout.trim().to_string())
}

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

pub fn get_cluster_config_with_secrets(
    lab: &serde_json::Value,
    cluster_name: &str,
) -> Result<serde_json::Value> {
    let mut cluster_config = get_cluster_config_from_lab(lab, cluster_name)?;
    if let Some(secrets) = lab.get("secrets") {
        cluster_config["secrets"] = secrets.clone();
    }
    Ok(cluster_config)
}

pub fn get_cluster_config(ctx: &CataContext, cluster_name: &str) -> Result<serde_json::Value> {
    let lab_name = ctx.resolve_lab_name(None)?;
    let lab = get_lab_config(ctx, &lab_name)?;
    get_cluster_config_from_lab(&lab, cluster_name)
}

pub fn list_clusters(ctx: &CataContext) -> Result<Vec<String>> {
    let lab_name = ctx.resolve_lab_name(None)?;
    let lab = get_lab_config(ctx, &lab_name)?;
    let names = lab
        .get("clusterNames")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();
    Ok(names)
}

pub fn current_system() -> String {
    let arch = std::env::consts::ARCH;
    let os = std::env::consts::OS;

    let nix_arch = arch;
    let nix_os = match os {
        "macos" => "darwin",
        "linux" => "linux",
        _ => os,
    };

    format!("{nix_arch}-{nix_os}")
}

pub fn get_lab_config(ctx: &CataContext, lab_name: &str) -> Result<serde_json::Value> {
    let cache_key = format!("{}#{}", ctx.flake_uri(), lab_name);
    if let Some(cached) = lab_config_cache()
        .lock()
        .expect("lab config cache mutex poisoned")
        .get(&cache_key)
    {
        return Ok(cached.clone());
    }

    refresh_path_inputs(ctx.flake_uri());
    let system = current_system();
    let value: serde_json::Value =
        eval_flake(ctx, &format!("legacyPackages.{system}.labs.\"{lab_name}\""))?;

    lab_config_cache()
        .lock()
        .expect("lab config cache mutex poisoned")
        .insert(cache_key, value.clone());
    Ok(value)
}

pub fn eval_lab(ctx: &CataContext, lab_name: &str) -> Result<LabSpec> {
    let value = get_lab_config(ctx, lab_name)?;
    LabSpec::from_value(value).context("Failed to parse lab config into LabSpec")
}

pub fn eval_cluster_from_lab(lab: &LabSpec, cluster_name: &str) -> Result<ClusterSpec> {
    lab.clusters.get(cluster_name).cloned().ok_or_else(|| {
        let available: Vec<&str> = lab.clusters.keys().map(String::as_str).collect();
        anyhow::anyhow!(
            "cluster '{}' not found in lab (available: {})",
            cluster_name,
            available.join(", ")
        )
    })
}

pub fn list_labs(ctx: &CataContext) -> Result<Vec<String>> {
    let uri = ctx.flake_uri();
    let system = current_system();
    let installable = format!("{uri}#legacyPackages.{system}.labs");

    let stdout = run_nix(&[
        "eval",
        "--json",
        &installable,
        "--apply",
        "builtins.attrNames",
    ])?;
    serde_json::from_str(&stdout).context("Failed to parse lab list")
}

pub fn list_labs_with_cluster_counts(ctx: &CataContext) -> Result<Vec<(String, usize)>> {
    let uri = ctx.flake_uri();
    let system = current_system();
    let installable = format!("{uri}#legacyPackages.{system}.labs");

    let stdout = run_nix(&[
        "eval",
        "--json",
        &installable,
        "--apply",
        "labs: builtins.mapAttrs (_: lab: builtins.length lab.clusterNames) labs",
    ])?;
    let map: std::collections::BTreeMap<String, usize> =
        serde_json::from_str(&stdout).context("Failed to parse lab-with-counts output")?;
    Ok(map.into_iter().collect())
}

pub fn build_lab_package(ctx: &CataContext, lab_name: &str) -> CataResult<String> {
    let system = current_system();
    build(
        ctx,
        &format!("legacyPackages.{system}.labPackages.\"{lab_name}\""),
    )
}

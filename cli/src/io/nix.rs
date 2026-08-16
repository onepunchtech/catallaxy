use std::collections::HashMap;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{Mutex, OnceLock};

use anyhow::{Context, Result, bail};
use console::style;
use serde::de::DeserializeOwned;

use crate::config::Context as CataContext;
use crate::domain::{ClusterSpec, LabSpec};

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

fn run_nix(args: &[&str]) -> Result<String> {
    run_nix_with_stderr(args, Stdio::inherit)
}

fn run_nix_quiet(args: &[&str]) -> Result<String> {
    run_nix_with_stderr(args, Stdio::piped)
}

fn run_nix_with_stderr(args: &[&str], stderr: fn() -> Stdio) -> Result<String> {
    let mut cmd = Command::new("nix");
    cmd.args(args).stdout(Stdio::piped()).stderr(stderr());
    crate::io::process::prepare_env(&mut cmd);
    let child = cmd
        .spawn()
        .context("nix evaluation failed: failed to spawn nix")?;

    let output = child
        .wait_with_output()
        .context("nix evaluation failed: failed to wait for nix")?;

    if !output.status.success() {
        let captured = String::from_utf8_lossy(&output.stderr);
        let detail = if captured.trim().is_empty() {
            String::new()
        } else {
            format!(": {}", captured.trim())
        };
        bail!(
            "nix evaluation failed: nix {} failed (exit {}){detail}",
            args[0],
            output.status.code().unwrap_or(-1),
        );
    }

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

pub fn eval_flake<T: DeserializeOwned>(ctx: &CataContext, attr: &str) -> Result<T> {
    let uri = ctx.flake_uri();
    let installable = format!("{uri}#{attr}");

    let stdout = run_nix(&["eval", "--json", &installable])?;
    serde_json::from_str(&stdout).context("Failed to parse nix eval output")
}

fn eval_flake_quiet<T: DeserializeOwned>(ctx: &CataContext, attr: &str) -> Result<T> {
    let uri = ctx.flake_uri();
    let installable = format!("{uri}#{attr}");

    let stdout = run_nix_quiet(&["eval", "--json", &installable])?;
    serde_json::from_str(&stdout).context("Failed to parse nix eval output")
}

pub fn build(ctx: &CataContext, attr: &str) -> Result<String> {
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

pub fn get_cluster_spec_from_lab(
    lab: &serde_json::Value,
    cluster_name: &str,
) -> Result<ClusterSpec> {
    let config = get_cluster_config_from_lab(lab, cluster_name)?;
    ClusterSpec::from_value(config)
        .with_context(|| format!("parsing the evaluated config for cluster '{cluster_name}'"))
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
        match eval_flake_quiet(ctx, &format!("legacyPackages.{system}.labs.\"{lab_name}\"")) {
            Ok(v) => v,
            Err(e) => return Err(explain_unknown_lab(ctx, lab_name).unwrap_or(e)),
        };

    lab_config_cache()
        .lock()
        .expect("lab config cache mutex poisoned")
        .insert(cache_key, value.clone());
    Ok(value)
}

fn explain_unknown_lab(ctx: &CataContext, lab_name: &str) -> Option<anyhow::Error> {
    let known = list_labs(ctx).ok()?;
    if known.iter().any(|l| l == lab_name) {
        return None;
    }

    let suggestion = nearest(lab_name, &known)
        .map(|near| format!("\nDid you mean '{near}'?"))
        .unwrap_or_default();

    Some(anyhow::anyhow!(
        "lab '{lab_name}' is not in this flake. Available: {}{}",
        if known.is_empty() {
            "(none)".to_string()
        } else {
            known.join(", ")
        },
        suggestion,
    ))
}

fn nearest<'a>(needle: &str, haystack: &'a [String]) -> Option<&'a str> {
    haystack
        .iter()
        .map(|candidate| (edit_distance(needle, candidate), candidate.as_str()))
        .filter(|(distance, _)| *distance <= needle.len().div_ceil(3).max(2))
        .min_by_key(|(distance, _)| *distance)
        .map(|(_, candidate)| candidate)
}

fn edit_distance(a: &str, b: &str) -> usize {
    let b_chars: Vec<char> = b.chars().collect();
    let mut previous: Vec<usize> = (0..=b_chars.len()).collect();
    let mut current = vec![0; b_chars.len() + 1];

    for (i, a_char) in a.chars().enumerate() {
        current[0] = i + 1;
        for (j, b_char) in b_chars.iter().enumerate() {
            let substitution = previous[j] + usize::from(a_char != *b_char);
            current[j + 1] = substitution.min(previous[j + 1] + 1).min(current[j] + 1);
        }
        std::mem::swap(&mut previous, &mut current);
    }
    previous[b_chars.len()]
}

pub fn get_lab_spec(ctx: &CataContext, lab_name: &str) -> Result<LabSpec> {
    let value = get_lab_config(ctx, lab_name)?;
    LabSpec::from_value(value)
        .with_context(|| format!("parsing the evaluated config for lab '{lab_name}'"))
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

#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LabSummary {
    pub clusters: usize,
    #[serde(default)]
    pub eligible: bool,
    #[serde(default)]
    pub reasons: Vec<String>,
}

pub fn list_labs_with_cluster_counts(ctx: &CataContext) -> Result<Vec<(String, LabSummary)>> {
    let uri = ctx.flake_uri();
    let system = current_system();
    let installable = format!("{uri}#legacyPackages.{system}.labs");

    let stdout = run_nix(&[
        "eval",
        "--json",
        &installable,
        "--apply",
        "labs: builtins.mapAttrs (_: lab: {
           clusters = builtins.length lab.clusterNames;
           eligible = lab.selfContained.eligible or true;
           reasons = lab.selfContained.reasons or [];
         }) labs",
    ])?;
    let map: std::collections::BTreeMap<String, LabSummary> =
        serde_json::from_str(&stdout).context("Failed to parse lab-with-counts output")?;
    Ok(map.into_iter().collect())
}

pub fn build_lab_package(ctx: &CataContext, lab_name: &str) -> Result<String> {
    let system = current_system();
    build(
        ctx,
        &format!("legacyPackages.{system}.labPackages.\"{lab_name}\""),
    )
}

pub fn build_out_path(attr: &str) -> anyhow::Result<String> {
    let mut cmd = std::process::Command::new("nix");
    cmd.args(["build", "--no-link", "--print-out-paths", attr]);
    Ok(crate::io::process::run_capture(&mut cmd)?
        .trim()
        .to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_one_character_typo_finds_its_lab() {
        let labs = vec![
            "minimal.local".to_string(),
            "homelab.local".to_string(),
            "mesh.local".to_string(),
        ];
        assert_eq!(nearest("minimal.locl", &labs), Some("minimal.local"));
        assert_eq!(nearest("homelab.loca", &labs), Some("homelab.local"));
    }

    #[test]
    fn something_unrelated_suggests_nothing() {
        let labs = vec!["minimal.local".to_string()];
        assert_eq!(nearest("production-eu-west", &labs), None);
    }

    #[test]
    fn no_labs_suggests_nothing() {
        assert_eq!(nearest("anything", &[]), None);
    }
}

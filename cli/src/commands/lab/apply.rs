#![allow(unused_imports)]

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use anyhow::{Context, Result, bail};
use console::style;

use crate::commands::kubeconfig;
use crate::config::Context as CataContext;
use crate::io;

use super::{dns, orchestrate, pki, publish, services, state};

pub async fn run(
    ctx: &CataContext,
    name: &str,
    bundle: Option<String>,
    dry_run: bool,
    force: bool,
) -> Result<()> {
    let lab = crate::io::nix::get_lab_config(ctx, name)?;

    println!("{} Applying lab '{name}'", style("catallaxy").cyan().bold());

    let mut secrets_cache: Option<crate::commands::apply::SecretsCache> = None;
    if let Some(stores) = lab.pointer("/secrets/stores").and_then(|v| v.as_object()) {
        let store_names: Vec<&str> = stores
            .iter()
            .filter(|(_, v)| v.pointer("/backend").and_then(|b| b.as_str()) == Some("sops"))
            .map(|(k, _)| k.as_str())
            .collect();
        if !store_names.is_empty() {
            println!(
                "{} Decrypting {} secret store(s) (cached for the rest of the run)...",
                style(">>>").cyan(),
                store_names.len(),
            );
            let mut cache = std::collections::HashMap::new();
            for store_name in &store_names {
                let enc_path = crate::commands::secrets::store_file_path(ctx, name, store_name);
                if !enc_path.exists() {
                    bail!(
                        "Secret store '{}' not found at {}. Run `cata secrets generate` first.",
                        store_name,
                        enc_path.display()
                    );
                }
                let data = crate::commands::secrets::decrypt_sops_store(&enc_path)?;
                crate::commands::secrets::validate_store_against_managed_with_config(
                    ctx,
                    Some(name),
                    store_name,
                    &data,
                    Some(&lab),
                )?;
                cache.insert(store_name.to_string(), data);
                println!("{} Decrypted store '{}'", style(">>>").green(), store_name);
            }
            secrets_cache = Some(std::sync::Arc::new(cache));

            if let Some(ref cache) = secrets_cache {
                state::project_host_secrets(&lab, cache, name)?;
            }
        }
    }

    println!("{} Building lab manifests...", style(">>>").cyan());
    let lab_package = crate::io::nix::build_lab_package(ctx, name)?;

    let cluster_names: Vec<String> = lab["clusterNames"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();

    for cluster_name in &cluster_names {
        let cluster_manifests = format!("{lab_package}/manifests/{cluster_name}");
        crate::commands::apply::run(
            ctx,
            crate::commands::apply::ApplyArgs {
                cluster: Some(cluster_name.to_string()),
                bundle: bundle.clone(),
                dry_run,
                force,
                manifests_dir: Some(cluster_manifests),
                secrets_cache: secrets_cache.clone(),
                lab_config: Some(lab.clone()),
                kube_context_override: None,
            },
        )
        .await?;
    }

    Ok(())
}

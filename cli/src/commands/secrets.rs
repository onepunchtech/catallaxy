//! Secrets management commands
//!
//! SOPS-based secret encryption and decryption, plus managed secret lifecycle.

use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use clap::Subcommand;
use console::style;
use serde::Deserialize;

use crate::config::Context as CataContext;
use crate::{generators, nix};

#[derive(Subcommand)]
pub enum SecretsCommands {
    /// Decrypt, edit, and re-encrypt a secrets file
    Edit {
        /// Path to the encrypted file
        file: String,
    },

    /// Encrypt a plaintext file
    Encrypt {
        /// Path to the plaintext file
        file: String,

        /// Output path (default: <file>.enc.yaml)
        #[arg(long)]
        output: Option<String>,
    },

    /// Decrypt a file to stdout
    Decrypt {
        /// Path to the encrypted file
        file: String,
    },

    /// Rotate encryption keys on a SOPS file
    Rotate {
        /// Path to the encrypted file
        file: String,
    },

    /// Generate values for managed secrets and encrypt with SOPS
    Generate {
        /// Cluster name
        cluster: Option<String>,

        /// Only generate a specific secret
        #[arg(long)]
        secret: Option<String>,

        /// Force regeneration even if values already exist
        #[arg(long)]
        force: bool,
    },

    /// List managed secrets and their status
    List {
        /// Cluster name
        cluster: Option<String>,
    },
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ManagedSecret {
    namespace: String,
    phase: String,
    backend: String,
    keys: HashMap<String, SecretKeyDef>,
    #[allow(dead_code)]
    remote_ref: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SecretKeyDef {
    generator: Option<String>,
    length: Option<u64>,
}

pub async fn run(ctx: &CataContext, command: SecretsCommands) -> Result<()> {
    match command {
        SecretsCommands::Edit { file } => {
            crate::tools::check_tool("sops")?;
            edit(ctx, &file).await
        }
        SecretsCommands::Encrypt { file, output } => {
            crate::tools::check_tool("sops")?;
            encrypt(ctx, &file, output.as_deref()).await
        }
        SecretsCommands::Decrypt { file } => {
            crate::tools::check_tool("sops")?;
            decrypt(ctx, &file).await
        }
        SecretsCommands::Rotate { file } => {
            crate::tools::check_tool("sops")?;
            rotate(ctx, &file).await
        }
        SecretsCommands::Generate {
            cluster,
            secret,
            force,
        } => {
            crate::tools::check_tool("sops")?;
            generate(ctx, cluster.as_deref(), secret.as_deref(), force).await
        }
        SecretsCommands::List { cluster } => list(ctx, cluster.as_deref()).await,
    }
}

async fn edit(_ctx: &CataContext, file: &str) -> Result<()> {
    println!(
        "{} Editing secrets file: {file}",
        style("catallaxy").cyan().bold()
    );

    let status = std::process::Command::new("sops")
        .arg(file)
        .status()
        .context("Failed to run sops")?;

    if !status.success() {
        bail!("sops edit failed");
    }

    println!("{} File saved and encrypted", style(">>>").green());
    Ok(())
}

async fn encrypt(_ctx: &CataContext, file: &str, output: Option<&str>) -> Result<()> {
    let output_path = output
        .map(|s| s.to_string())
        .unwrap_or_else(|| format!("{file}.enc.yaml"));

    println!(
        "{} Encrypting: {file} -> {output_path}",
        style("catallaxy").cyan().bold()
    );

    let status = std::process::Command::new("sops")
        .args(["--encrypt", file, "--output", &output_path])
        .status()
        .context("Failed to run sops")?;

    if !status.success() {
        bail!("sops encrypt failed");
    }

    println!("{} File encrypted", style(">>>").green());
    Ok(())
}

async fn decrypt(_ctx: &CataContext, file: &str) -> Result<()> {
    let output = std::process::Command::new("sops")
        .args(["--decrypt", file])
        .output()
        .context("Failed to run sops")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!("sops decrypt failed: {stderr}");
    }

    print!("{}", String::from_utf8_lossy(&output.stdout));
    Ok(())
}

async fn rotate(_ctx: &CataContext, file: &str) -> Result<()> {
    println!(
        "{} Rotating keys for: {file}",
        style("catallaxy").cyan().bold()
    );

    let status = std::process::Command::new("sops")
        .args(["rotate", "--in-place", file])
        .status()
        .context("Failed to run sops")?;

    if !status.success() {
        bail!("sops rotate failed");
    }

    println!("{} Keys rotated", style(">>>").green());
    Ok(())
}

fn get_managed_secrets(
    ctx: &CataContext,
    cluster: Option<&str>,
) -> Result<(String, HashMap<String, ManagedSecret>)> {
    let cluster_name = ctx.resolve_cluster_name(cluster)?;
    let config = nix::get_cluster_config(ctx, &cluster_name)?;

    let secrets_value = config
        .get("secrets")
        .ok_or_else(|| anyhow::anyhow!("No 'secrets' found in cluster config"))?;

    let secrets: HashMap<String, ManagedSecret> = serde_json::from_value(secrets_value.clone())?;

    Ok((cluster_name, secrets))
}

fn secrets_dir(ctx: &CataContext, cluster_name: &str) -> PathBuf {
    let flake_root = PathBuf::from(ctx.flake_uri());
    flake_root.join("secrets").join(cluster_name)
}

fn secret_file_path(ctx: &CataContext, cluster_name: &str, secret_name: &str) -> PathBuf {
    secrets_dir(ctx, cluster_name).join(format!("{secret_name}.enc.yaml"))
}

async fn generate(
    ctx: &CataContext,
    cluster: Option<&str>,
    only_secret: Option<&str>,
    force: bool,
) -> Result<()> {
    let (cluster_name, secrets) = get_managed_secrets(ctx, cluster)?;

    println!(
        "{} Generating secrets for cluster '{cluster_name}'",
        style("catallaxy").cyan().bold()
    );

    let sops_secrets: Vec<(&String, &ManagedSecret)> = secrets
        .iter()
        .filter(|(_, s)| s.backend == "sops")
        .filter(|(name, _)| only_secret.map_or(true, |s| *name == s))
        .collect();

    if sops_secrets.is_empty() {
        println!("{} No SOPS secrets to generate", style(">>>").yellow());
        return Ok(());
    }

    // Ensure secrets directory exists
    let dir = secrets_dir(ctx, &cluster_name);
    fs::create_dir_all(&dir).context("Failed to create secrets directory")?;

    for (name, secret) in &sops_secrets {
        let path = secret_file_path(ctx, &cluster_name, name);

        if path.exists() && !force {
            println!(
                "{} Skipping {} (already exists, use --force to regenerate)",
                style(">>>").yellow(),
                name
            );
            continue;
        }

        // Generate values for keys with generators
        let mut data: HashMap<String, String> = HashMap::new();
        for (key_name, key_def) in &secret.keys {
            if let Some(ref generator) = key_def.generator {
                let value = generators::generate_value(generator, key_def.length)?;
                data.insert(key_name.clone(), value);
            } else {
                // Manual key — placeholder for user to fill via `secrets edit`
                data.insert(key_name.clone(), "PLACEHOLDER_USE_SECRETS_EDIT".to_string());
            }
        }

        // Write YAML and encrypt with SOPS
        let yaml = serde_yaml::to_string(&data)?;
        let mut tmpfile = tempfile::NamedTempFile::new()?;
        tmpfile.write_all(yaml.as_bytes())?;
        tmpfile.flush()?;

        let status = std::process::Command::new("sops")
            .args([
                "--encrypt",
                "--input-type",
                "yaml",
                "--output-type",
                "yaml",
                "--output",
                &path.display().to_string(),
            ])
            .arg(tmpfile.path())
            .status()
            .context("Failed to run sops encrypt")?;

        if !status.success() {
            bail!("Failed to encrypt secret '{name}'. Is .sops.yaml configured?");
        }

        println!(
            "{} Generated and encrypted: {} ({} keys)",
            style(">>>").green(),
            name,
            data.len()
        );
    }

    Ok(())
}

async fn list(ctx: &CataContext, cluster: Option<&str>) -> Result<()> {
    let (cluster_name, secrets) = get_managed_secrets(ctx, cluster)?;

    println!(
        "{} Managed secrets for cluster '{cluster_name}'",
        style("catallaxy").cyan().bold()
    );
    println!();

    if secrets.is_empty() {
        println!("  (none)");
        return Ok(());
    }

    for (name, secret) in &secrets {
        let path = secret_file_path(ctx, &cluster_name, name);
        let status = if secret.backend != "sops" {
            style("(managed by operator)").dim().to_string()
        } else if path.exists() {
            style("generated").green().to_string()
        } else {
            style("missing").red().to_string()
        };

        let key_names: Vec<&String> = secret.keys.keys().collect();
        println!(
            "  {} {} [{}]",
            style(name).bold(),
            status,
            style(format!(
                "ns:{}, phase:{}, backend:{}",
                secret.namespace, secret.phase, secret.backend
            ))
            .dim()
        );
        println!(
            "    keys: {}",
            key_names
                .iter()
                .map(|k| {
                    let def = &secret.keys[k.as_str()];
                    if let Some(ref generator) = def.generator {
                        format!("{k} ({generator})")
                    } else {
                        format!("{k} (manual)")
                    }
                })
                .collect::<Vec<_>>()
                .join(", ")
        );
    }

    Ok(())
}

/// Decrypt a SOPS secret file and return key-value pairs.
/// Used by the apply flow to inject secrets.
pub fn decrypt_sops_secret(path: &std::path::Path) -> Result<HashMap<String, String>> {
    let output = std::process::Command::new("sops")
        .args(["--decrypt", "--output-type", "yaml"])
        .arg(path)
        .output()
        .context("Failed to run sops decrypt")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!("sops decrypt failed for {}: {stderr}", path.display());
    }

    let yaml_str = String::from_utf8_lossy(&output.stdout);
    let data: HashMap<String, String> = serde_yaml::from_str(&yaml_str)?;
    Ok(data)
}

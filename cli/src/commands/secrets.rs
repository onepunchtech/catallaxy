use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use clap::Subcommand;
use console::style;
use serde::Deserialize;

use crate::config::Context as CataContext;
use crate::generators;
use crate::io::nix;

const STORE_HELP: &str = "Store name from lab.secrets.stores, or a path to an encrypted file";
const SECRETS_LAB_HELP: &str = "Lab to act on. Defaults to the flake fragment";

#[derive(Subcommand)]
pub enum SecretsCommands {
    #[command(about = "Decrypt a store, open it in $EDITOR, and re-encrypt on save")]
    Edit {
        #[arg(help = STORE_HELP)]
        store: String,
    },

    #[command(about = "Encrypt a plaintext file")]
    Encrypt {
        #[arg(help = "Plaintext file to encrypt")]
        file: String,

        #[arg(
            long,
            value_name = "PATH",
            help = "Where to write the ciphertext. Defaults to <FILE>.enc.yaml"
        )]
        output: Option<String>,
    },

    #[command(about = "Decrypt a store to stdout")]
    Decrypt {
        #[arg(help = STORE_HELP)]
        store: String,
    },

    #[command(about = "Re-encrypt a store to the current set of recipients")]
    Rotate {
        #[arg(help = STORE_HELP)]
        store: String,
    },

    #[command(about = "Mint values for generator-backed keys")]
    Generate {
        #[arg(value_name = "LAB", help = SECRETS_LAB_HELP)]
        cluster: Option<String>,

        #[arg(long, value_name = "NAME", help = "Generate only this secret")]
        secret: Option<String>,

        #[arg(long, help = "Regenerate stores that already exist")]
        force: bool,

        #[arg(long, help = "Print the plaintext YAML shape without writing anything")]
        example: bool,
    },

    #[command(about = "List managed secrets and their status")]
    List {
        #[arg(value_name = "LAB", help = SECRETS_LAB_HELP)]
        cluster: Option<String>,
    },
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SecretStore {
    backend: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ManagedSecret {
    store: String,
    keys: HashMap<String, ManagedKeyDef>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ManagedKeyDef {
    generator: Option<String>,
    length: Option<u64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
#[allow(dead_code)]
struct Projection {
    source: String,
    namespace: String,
    keys: HashMap<String, ProjectionKeyDef>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
#[allow(dead_code)]
struct ProjectionKeyDef {
    from: String,
    transform: Option<String>,
    json_key: Option<String>,
}

#[derive(Debug)]
struct LabSecrets {
    lab_name: String,
    stores: HashMap<String, SecretStore>,
    managed: HashMap<String, ManagedSecret>,
    projections: Vec<(String, String, Projection)>,
}

pub async fn run(ctx: &CataContext, command: SecretsCommands) -> Result<()> {
    match command {
        SecretsCommands::Edit { store } => {
            crate::io::process::check_tool("sops")?;
            let path = resolve_store_or_path(ctx, &store)?;
            edit(ctx, &path).await
        }
        SecretsCommands::Encrypt { file, output } => {
            crate::io::process::check_tool("sops")?;
            encrypt(ctx, &file, output.as_deref()).await
        }
        SecretsCommands::Decrypt { store } => {
            crate::io::process::check_tool("sops")?;
            let path = resolve_store_or_path(ctx, &store)?;
            decrypt(ctx, &path).await
        }
        SecretsCommands::Rotate { store } => {
            crate::io::process::check_tool("sops")?;
            let path = resolve_store_or_path(ctx, &store)?;
            rotate(ctx, &path).await
        }
        SecretsCommands::Generate {
            cluster,
            secret,
            force,
            example,
        } => {
            if !example {
                crate::io::process::check_tool("sops")?;
            }
            generate(ctx, cluster.as_deref(), secret.as_deref(), force, example).await
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

fn get_lab_secrets(ctx: &CataContext, name: Option<&str>) -> Result<LabSecrets> {
    let lab_name = ctx.resolve_lab_name(name)?;
    let lab = nix::get_lab_config(ctx, &lab_name)?;
    parse_lab_secrets(&lab_name, &lab)
}

fn parse_lab_secrets(lab_name: &str, lab: &serde_json::Value) -> Result<LabSecrets> {
    let lab_name = lab_name.to_string();

    let stores: HashMap<String, SecretStore> = lab
        .pointer("/secrets/stores")
        .and_then(|v| serde_json::from_value(v.clone()).ok())
        .unwrap_or_default();

    let managed: HashMap<String, ManagedSecret> = lab
        .pointer("/secrets/managed")
        .and_then(|v| serde_json::from_value(v.clone()).ok())
        .unwrap_or_default();

    let mut projections = Vec::new();
    if let Some(clusters) = lab.pointer("/clusters").and_then(|v| v.as_object()) {
        for (cname, cconfig) in clusters {
            if let Some(projs) = cconfig.get("projections") {
                if let Ok(cluster_projs) =
                    serde_json::from_value::<HashMap<String, Projection>>(projs.clone())
                {
                    for (pname, proj) in cluster_projs {
                        projections.push((cname.clone(), pname, proj));
                    }
                }
            }
        }
    }

    Ok(LabSecrets {
        lab_name,
        stores,
        managed,
        projections,
    })
}

pub fn store_file_path(ctx: &CataContext, lab_name: &str, store_name: &str) -> PathBuf {
    let flake_root = PathBuf::from(ctx.flake_uri());
    let filename = format!("{store_name}.enc.yaml");

    let primary = flake_root.join("secrets").join(lab_name).join(&filename);
    if primary.exists() {
        return primary;
    }

    let fallback = flake_root
        .join("examples/labs/secrets")
        .join(lab_name)
        .join(&filename);
    if fallback.exists() {
        return fallback;
    }

    primary
}

fn resolve_store_or_path(ctx: &CataContext, input: &str) -> Result<String> {
    if input.contains('/') || input.contains('.') {
        return Ok(input.to_string());
    }
    let lab_name = ctx.resolve_lab_name(None)?;
    let path = store_file_path(ctx, &lab_name, input);
    if !path.exists() {
        bail!(
            "Store file not found: {}\nRun 'secrets generate' first, or pass a file path directly.",
            path.display()
        );
    }
    Ok(path.display().to_string())
}

async fn generate(
    ctx: &CataContext,
    _cluster: Option<&str>,
    only_secret: Option<&str>,
    force: bool,
    example: bool,
) -> Result<()> {
    let lab = get_lab_secrets(ctx, _cluster)?;

    if !example {
        println!(
            "{} Generating secrets for lab '{}'",
            style("catallaxy").cyan().bold(),
            lab.lab_name,
        );
    }

    let sops_stores: Vec<&String> = lab
        .stores
        .iter()
        .filter(|(_, s)| s.backend == "sops")
        .map(|(name, _)| name)
        .collect();

    if sops_stores.is_empty() {
        println!("{} No SOPS stores to generate", style(">>>").yellow());
        return Ok(());
    }

    for store_name in &sops_stores {
        let path = store_file_path(ctx, &lab.lab_name, store_name);

        if !example && path.exists() && !force {
            println!(
                "{} Skipping store '{}' (already exists, use --force to regenerate or --example to print)",
                style(">>>").yellow(),
                store_name
            );
            continue;
        }

        let store_secrets: Vec<(&String, &ManagedSecret)> = lab
            .managed
            .iter()
            .filter(|(_, sec)| &sec.store == *store_name)
            .filter(|(name, _)| only_secret.map_or(true, |s| *name == s))
            .collect();

        if store_secrets.is_empty() {
            continue;
        }

        let mut data: serde_json::Map<String, serde_json::Value> = serde_json::Map::new();
        for (secret_name, secret) in &store_secrets {
            let mut secret_data = serde_json::Map::new();
            for (key_name, key_def) in &secret.keys {
                let value = if let Some(ref generator) = key_def.generator {
                    if example {
                        match key_def.length {
                            Some(len) => format!("<{generator}:{len}>"),
                            None => format!("<{generator}>"),
                        }
                    } else {
                        generators::generate_value(generator, key_def.length)?
                    }
                } else {
                    "PLACEHOLDER_USE_SECRETS_EDIT".to_string()
                };
                secret_data.insert(key_name.clone(), serde_json::Value::String(value));
            }
            data.insert(
                (*secret_name).clone(),
                serde_json::Value::Object(secret_data),
            );
        }

        if example {
            let yaml = serde_yaml::to_string(&data)?;
            println!("# store: {} ({})", store_name, path.display());
            println!("# Diff this against the decrypted contents of the file above:");
            println!(
                "#   cata secrets decrypt {store_name} | diff - <(cata secrets generate --example | sed -n '/^# store: {store_name}/,/^# store:/p')"
            );
            println!("{yaml}");
            continue;
        }

        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).context("Failed to create secrets directory")?;
        }

        let yaml = serde_yaml::to_string(&data)?;
        let mut tmpfile = tempfile::NamedTempFile::new()?;
        tmpfile.write_all(yaml.as_bytes())?;
        tmpfile.flush()?;

        let sops_match_path = format!("secrets/{}/{store_name}.enc.yaml", lab.lab_name);
        let flake_root = PathBuf::from(ctx.flake_uri());

        let status = std::process::Command::new("sops")
            .current_dir(&flake_root)
            .args([
                "--encrypt",
                "--input-type",
                "yaml",
                "--output-type",
                "yaml",
                "--filename-override",
                &sops_match_path,
                "--output",
                &path.display().to_string(),
            ])
            .arg(tmpfile.path())
            .status()
            .context("Failed to run sops encrypt")?;

        if !status.success() {
            bail!("Failed to encrypt store '{store_name}'. Is .sops.yaml configured?");
        }

        let key_count: usize = store_secrets.iter().map(|(_, s)| s.keys.len()).sum();
        println!(
            "{} Generated store: {} ({} secrets, {} keys)",
            style(">>>").green(),
            store_name,
            store_secrets.len(),
            key_count,
        );
    }

    Ok(())
}

async fn list(ctx: &CataContext, cluster: Option<&str>) -> Result<()> {
    let lab = get_lab_secrets(ctx, cluster)?;

    println!(
        "{} Secrets for lab '{}'",
        style("catallaxy").cyan().bold(),
        lab.lab_name,
    );
    println!();

    if !lab.stores.is_empty() {
        println!("{}", style("Stores:").bold());
        for (name, store) in &lab.stores {
            let path = store_file_path(ctx, &lab.lab_name, name);
            let status = if path.exists() {
                style("generated").green()
            } else {
                style("missing").red()
            };
            println!(
                "  {} ({}) → {} [{}]",
                style(name).bold(),
                store.backend,
                path.display(),
                status,
            );
        }
        println!();
    }

    if !lab.managed.is_empty() {
        println!("{}", style("Managed secrets:").bold());
        for (name, secret) in &lab.managed {
            let key_list: String = secret
                .keys
                .iter()
                .map(|(k, def)| {
                    if let Some(ref generator) = def.generator {
                        format!("{k} ({generator})")
                    } else {
                        format!("{k} (manual)")
                    }
                })
                .collect::<Vec<_>>()
                .join(", ");
            println!(
                "  {} [store: {}] keys: {}",
                style(name).bold(),
                secret.store,
                key_list,
            );
        }
        println!();
    }

    if !lab.projections.is_empty() {
        println!("{}", style("Projections:").bold());
        for (cluster_name, proj_name, proj) in &lab.projections {
            let key_list: String = proj
                .keys
                .iter()
                .map(|(k, def)| {
                    let transform = def.transform.as_deref().unwrap_or("none");
                    if transform == "none" {
                        format!("{k}←{}", def.from)
                    } else {
                        format!("{k}←{}({})", def.from, transform)
                    }
                })
                .collect::<Vec<_>>()
                .join(", ");
            println!(
                "  {} → {} [ns:{}, from:{}] {}",
                style(cluster_name).dim(),
                style(proj_name).bold(),
                proj.namespace,
                proj.source,
                key_list,
            );
        }
        println!();
    }

    if lab.stores.is_empty() && lab.managed.is_empty() {
        println!("  (none)");
    }

    Ok(())
}

pub fn validate_store_against_managed(
    ctx: &CataContext,
    lab_name: Option<&str>,
    store_name: &str,
    decrypted: &HashMap<String, HashMap<String, String>>,
) -> Result<()> {
    validate_store_against_managed_with_config(ctx, lab_name, store_name, decrypted, None)
}

pub fn validate_store_against_managed_with_config(
    ctx: &CataContext,
    lab_name: Option<&str>,
    store_name: &str,
    decrypted: &HashMap<String, HashMap<String, String>>,
    lab_config: Option<&serde_json::Value>,
) -> Result<()> {
    let lab = if let Some(config) = lab_config {
        let name = ctx.resolve_lab_name(lab_name)?;
        parse_lab_secrets(&name, config)?
    } else {
        get_lab_secrets(ctx, lab_name)?
    };

    let mut missing_secrets: Vec<String> = Vec::new();
    let mut missing_keys: Vec<(String, Vec<String>)> = Vec::new();
    let mut blank_keys: Vec<(String, String)> = Vec::new();

    for (sec_name, sec) in lab.managed.iter().filter(|(_, s)| s.store == store_name) {
        match decrypted.get(sec_name) {
            None => missing_secrets.push(sec_name.clone()),
            Some(actual) => {
                let mut sec_missing: Vec<String> = Vec::new();
                for declared_key in sec.keys.keys() {
                    match actual.get(declared_key) {
                        None => sec_missing.push(declared_key.clone()),
                        Some(v) if v.is_empty() => {
                            blank_keys.push((sec_name.clone(), declared_key.clone()))
                        }
                        _ => {}
                    }
                }
                if !sec_missing.is_empty() {
                    missing_keys.push((sec_name.clone(), sec_missing));
                }
            }
        }
    }

    if missing_secrets.is_empty() && missing_keys.is_empty() && blank_keys.is_empty() {
        return Ok(());
    }

    let mut msg = format!(
        "Store '{}' is missing values declared in lab.secrets.managed:\n",
        store_name
    );
    for sec in &missing_secrets {
        msg.push_str(&format!("  - secret '{}' (no entry in SOPS file)\n", sec));
    }
    for (sec, keys) in &missing_keys {
        msg.push_str(&format!(
            "  - secret '{}': missing keys [{}]\n",
            sec,
            keys.join(", ")
        ));
    }
    for (sec, key) in &blank_keys {
        msg.push_str(&format!(
            "  - secret '{}': key '{}' is empty (operator-supplied, fill it in)\n",
            sec, key
        ));
    }
    msg.push_str(&format!(
        "\nRun:\n  cata secrets generate   # mint values for generator-backed keys\n  \
         cata secrets edit {} {}   # fill operator-supplied keys",
        lab.lab_name, store_name
    ));
    bail!(msg);
}

pub fn decrypt_sops_store(
    path: &std::path::Path,
) -> Result<HashMap<String, HashMap<String, String>>> {
    use std::process::Stdio;

    let output = std::process::Command::new("sops")
        .args(["--decrypt", "--output-type", "yaml"])
        .arg(path)
        .stdin(Stdio::inherit())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .output()
        .context("Failed to run sops decrypt")?;

    if !output.status.success() {
        bail!("sops decrypt failed for {}", path.display());
    }

    let yaml_str = String::from_utf8_lossy(&output.stdout);
    let data: HashMap<String, HashMap<String, String>> = serde_yaml::from_str(&yaml_str)?;
    Ok(data)
}

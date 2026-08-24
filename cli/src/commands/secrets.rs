use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use clap::{Subcommand, ValueEnum};
use console::style;
use serde::Deserialize;

use crate::config::Context as CataContext;
use crate::domain::secrets::{
    self as secrets, Backend, SecretKind, SecretsSpec, StoreProblem, StoreValues,
    describe_store_problems, env_var_name,
};
use crate::generators;
use crate::io::nix;
use crate::io::pki;

const STORE_HELP: &str = "Store name from lab.secrets.stores, or a path to an encrypted file";
const SECRETS_LAB_HELP: &str = "Lab to act on. Defaults to the flake fragment";
const CA_ALGORITHM: crate::io::pki::KeyAlgorithm = crate::io::pki::KeyAlgorithm::EcdsaP256;
const ROOT_CA_DAYS: u32 = 3650;

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum GenerateFormat {
    Sops,
    Env,
}

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

        #[arg(long, help = "Print the plaintext shape without writing anything")]
        example: bool,

        #[arg(
            long,
            value_enum,
            default_value = "sops",
            help = "sops encrypts the store files; env prints the VAR=value lines an env-backed store reads, and writes nothing"
        )]
        format: GenerateFormat,
    },

    #[command(about = "Mint an intermediate CA signed by the lab's root CA")]
    InitIntermediate {
        #[arg(
            value_name = "NAME",
            help = "Managed secret to hold the intermediate. Must be declared with kind = \"ca\""
        )]
        name: String,

        #[arg(
            long,
            value_name = "NAME",
            help = "Root CA to sign with. Defaults to the only other kind = \"ca\" secret in the store"
        )]
        root: Option<String>,

        #[arg(long, default_value = "365", help = "Validity in days")]
        days: u32,

        #[arg(
            long,
            help = "Replace an intermediate that is already in the store, reissuing every leaf under it"
        )]
        force: bool,
    },

    #[command(about = "List managed secrets and their status")]
    List {
        #[arg(value_name = "LAB", help = SECRETS_LAB_HELP)]
        cluster: Option<String>,
    },
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Projection {
    source: String,
    namespace: String,
    keys: HashMap<String, ProjectionKeyDef>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProjectionKeyDef {
    from: String,
    transform: Option<String>,
}

#[derive(Debug)]
struct LabSecrets {
    lab_name: String,
    spec: SecretsSpec,
    projections: Vec<(String, String, Projection)>,
}

pub fn run(ctx: &CataContext, command: SecretsCommands) -> Result<()> {
    match command {
        SecretsCommands::Edit { store } => {
            let path = resolve_store_or_path(ctx, &store)?;
            crate::io::process::check_tool("sops")?;
            edit(ctx, &path)
        }
        SecretsCommands::Encrypt { file, output } => {
            crate::io::process::check_tool("sops")?;
            encrypt(ctx, &file, output.as_deref())
        }
        SecretsCommands::Decrypt { store } => {
            let path = resolve_store_or_path(ctx, &store)?;
            crate::io::process::check_tool("sops")?;
            decrypt(ctx, &path)
        }
        SecretsCommands::Rotate { store } => {
            let path = resolve_store_or_path(ctx, &store)?;
            crate::io::process::check_tool("sops")?;
            rotate(ctx, &path)
        }
        SecretsCommands::Generate {
            cluster,
            secret,
            force,
            example,
            format,
        } => generate(
            ctx,
            cluster.as_deref(),
            secret.as_deref(),
            force,
            Minting::of_example_flag(example),
            format,
        ),
        SecretsCommands::InitIntermediate {
            name,
            root,
            days,
            force,
        } => init_intermediate(ctx, &name, root.as_deref(), days, force),
        SecretsCommands::List { cluster } => list(ctx, cluster.as_deref()),
    }
}

fn edit(_ctx: &CataContext, file: &str) -> Result<()> {
    println!(
        "{} Editing secrets file: {file}",
        style("catallaxy").cyan().bold()
    );

    let status = crate::io::sops::edit(file)?;

    if !status.success() {
        bail!("sops edit failed");
    }

    println!("{} File saved and encrypted", style(">>>").green());
    Ok(())
}

fn encrypt(_ctx: &CataContext, file: &str, output: Option<&str>) -> Result<()> {
    let output_path = output
        .map(|s| s.to_string())
        .unwrap_or_else(|| format!("{file}.enc.yaml"));

    println!(
        "{} Encrypting: {file} -> {output_path}",
        style("catallaxy").cyan().bold()
    );

    let status = crate::io::sops::encrypt_to(file, &output_path)?;

    if !status.success() {
        bail!("sops encrypt failed");
    }

    println!("{} File encrypted", style(">>>").green());
    Ok(())
}

fn decrypt(_ctx: &CataContext, file: &str) -> Result<()> {
    let output = crate::io::sops::decrypt_to_stdout(file)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!("sops decrypt failed: {stderr}");
    }

    print!("{}", String::from_utf8_lossy(&output.stdout));
    Ok(())
}

fn rotate(_ctx: &CataContext, file: &str) -> Result<()> {
    println!(
        "{} Rotating keys for: {file}",
        style("catallaxy").cyan().bold()
    );

    let status = crate::io::sops::rotate_in_place(file)?;

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
    let spec = SecretsSpec::from_lab_config(lab)?;

    let mut projections = Vec::new();
    if let Some(clusters) = lab.pointer("/clusters").and_then(|v| v.as_object()) {
        for (cname, cconfig) in clusters {
            if let Some(projs) = cconfig.get("projections")
                && let Ok(cluster_projs) =
                    serde_json::from_value::<HashMap<String, Projection>>(projs.clone())
            {
                for (pname, proj) in cluster_projs {
                    projections.push((cname.clone(), pname, proj));
                }
            }
        }
    }

    Ok(LabSecrets {
        lab_name: lab_name.to_string(),
        spec,
        projections,
    })
}

fn resolve_store_or_path(ctx: &CataContext, input: &str) -> Result<String> {
    if input.contains('/') || input.contains('.') {
        return Ok(input.to_string());
    }
    let lab = get_lab_secrets(ctx, None)?;
    let backend = lab.spec.backend_of(input);
    if backend != Backend::Sops {
        bail!(
            "Store '{input}' has backend {}, so there is no file to open.{}",
            backend.as_str(),
            env_store_hint(&lab.spec, input),
        );
    }

    let path = crate::io::secrets::store_file_path(ctx, &lab.lab_name, input);
    if path.exists() {
        return Ok(path.display().to_string());
    }

    bail!(
        "Store file not found: {}\nRun 'secrets generate' first, or pass a file path directly.",
        path.display()
    );
}

fn env_store_hint(spec: &SecretsSpec, store: &str) -> String {
    if spec.backend_of(store) != Backend::Env {
        return String::new();
    }
    let vars: Vec<String> = spec
        .env_bindings(store)
        .into_iter()
        .map(|b| b.var)
        .collect();
    let mut hint = format!(
        "\nIts values come from the environment: {}.",
        vars.join(", ")
    );
    if let Some(file) = spec.env_file.as_deref() {
        hint.push_str(&format!("\nThe lab sets them in {file}."));
    }
    hint
}

fn generate(
    ctx: &CataContext,
    _cluster: Option<&str>,
    only_secret: Option<&str>,
    force: bool,
    minting: Minting,
    format: GenerateFormat,
) -> Result<()> {
    let lab = get_lab_secrets(ctx, _cluster)?;

    if format == GenerateFormat::Env {
        return generate_env(&lab, only_secret, minting);
    }

    let sops_stores = lab.spec.stores_with(Backend::Sops);
    let env_stores = lab.spec.stores_with(Backend::Env);

    if sops_stores.is_empty() {
        if env_stores.is_empty() {
            println!("{} No stores to generate", style(">>>").yellow());
        } else {
            println!(
                "{} {} has backend env, so there is nothing to encrypt. \
                 `cata secrets generate --format env` prints the variables it reads.",
                style(">>>").yellow(),
                env_stores.join(", "),
            );
        }
        return Ok(());
    }

    if !minting.is_example() {
        crate::io::process::check_tool("sops")?;
        println!(
            "{} Generating secrets for lab '{}'",
            style("catallaxy").cyan().bold(),
            lab.lab_name,
        );
    }

    for store_name in &sops_stores {
        let path = crate::io::secrets::store_file_path(ctx, &lab.lab_name, store_name);

        if !minting.is_example() && path.exists() && !force {
            println!(
                "{} Skipping store '{}' (already exists, use --force to regenerate or --example to print)",
                style(">>>").yellow(),
                store_name
            );
            continue;
        }

        let existing = if !minting.is_example() && path.exists() {
            let held = crate::io::secrets::load_store(ctx, &lab.lab_name, store_name, &lab.spec)
                .with_context(|| {
                    format!(
                        "'{store_name}' already exists at {} but could not be decrypted. \
                         Regenerating would destroy the values it holds, so nothing was written.",
                        path.display(),
                    )
                })?;
            Some(held)
        } else {
            None
        };

        let data = mint_store(&lab, store_name, only_secret, minting, existing.as_ref())?;
        if data.is_empty() {
            continue;
        }

        if minting.is_example() {
            let yaml = serde_yaml::to_string(&data)?;
            println!("# store: {} ({})", store_name, path.display());
            println!("# Diff this against the decrypted contents of the file above:");
            println!(
                "#   cata secrets decrypt {store_name} | diff - <(cata secrets generate --example | sed -n '/^# store: {store_name}/,/^# store:/p')"
            );
            println!("{yaml}");
            continue;
        }

        write_sops_store(ctx, &lab.lab_name, store_name, &data)?;

        let key_count: usize = data.values().map(|keys| keys.len()).sum();
        println!(
            "{} Generated store: {} ({} secrets, {} keys)",
            style(">>>").green(),
            store_name,
            data.len(),
            key_count,
        );
    }

    Ok(())
}

fn generate_env(lab: &LabSecrets, only_secret: Option<&str>, minting: Minting) -> Result<()> {
    let env_stores = lab.spec.stores_with(Backend::Env);
    if env_stores.is_empty() {
        bail!(
            "lab '{}' declares no store with backend env, so there are no variables to print",
            lab.lab_name
        );
    }

    for store_name in &env_stores {
        let data = mint_store(lab, store_name, only_secret, minting, None)?;
        print_env_store(store_name, &data);
    }

    Ok(())
}

fn print_env_store(store_name: &str, data: &PlainStore) {
    for (secret_name, keys) in data {
        for (key_name, value) in keys {
            println!(
                "{}={}",
                env_var_name(store_name, secret_name, key_name),
                shell_quote(value),
            );
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Minting {
    Real,
    Example,
}

impl Minting {
    pub fn of_example_flag(example: bool) -> Self {
        if example {
            Minting::Example
        } else {
            Minting::Real
        }
    }

    pub fn is_example(self) -> bool {
        self == Minting::Example
    }
}

type PlainStore = BTreeMap<String, BTreeMap<String, String>>;

fn mint_store(
    lab: &LabSecrets,
    store_name: &str,
    only_secret: Option<&str>,
    minting: Minting,
    existing: Option<&StoreValues>,
) -> Result<PlainStore> {
    let mut data = PlainStore::new();

    for (secret_name, secret) in lab.spec.secrets_in(store_name) {
        if only_secret.is_some_and(|wanted| secret_name != wanted) {
            continue;
        }

        let held = existing.and_then(|values| values.get(secret_name));

        let keys = match secret.kind {
            SecretKind::Ca => match held {
                Some(prior) if !minting.is_example() && prior.contains_key(pki::CERT_KEY) => {
                    prior.clone().into_iter().collect()
                }
                _ => mint_ca(&lab.lab_name, secret_name, minting)?,
            },
            SecretKind::Value => secret
                .keys
                .iter()
                .map(|(key_name, key_def)| {
                    let kept = if minting.is_example() || key_def.generator.is_some() {
                        None
                    } else {
                        held.and_then(|prior| prior.get(key_name))
                            .filter(|v| !v.is_empty() && v.as_str() != secrets::PLACEHOLDER)
                            .cloned()
                    };
                    match kept {
                        Some(value) => Ok((key_name.clone(), value)),
                        None => mint(key_def.generator.as_deref(), key_def.length, minting)
                            .map(|value| (key_name.clone(), value)),
                    }
                })
                .collect::<Result<BTreeMap<String, String>>>()?,
        };

        if !keys.is_empty() {
            data.insert(secret_name.to_string(), keys);
        }
    }

    Ok(data)
}

fn mint_ca(
    lab_name: &str,
    secret_name: &str,
    minting: Minting,
) -> Result<BTreeMap<String, String>> {
    if minting.is_example() {
        return Ok(BTreeMap::from([
            (
                pki::CERT_KEY.to_string(),
                "<ca-certificate-pem>".to_string(),
            ),
            (pki::KEY_KEY.to_string(), "<ca-private-key-pem>".to_string()),
        ]));
    }

    let ca = pki::self_signed_ca(&ca_common_name(lab_name), CA_ALGORITHM, ROOT_CA_DAYS)?;
    println!(
        "{} Minted CA '{}' (CN={}, {} days, {})",
        style(">>>").green(),
        secret_name,
        ca_common_name(lab_name),
        ROOT_CA_DAYS,
        CA_ALGORITHM,
    );

    Ok(BTreeMap::from([
        (pki::CERT_KEY.to_string(), ca.cert_pem),
        (pki::KEY_KEY.to_string(), ca.key_pem),
    ]))
}

fn ca_common_name(lab_name: &str) -> String {
    format!("Catallaxy Lab CA ({lab_name})")
}

fn intermediate_common_name(lab_name: &str) -> String {
    format!("Catallaxy Lab Intermediate CA ({lab_name})")
}

fn write_sops_store(
    ctx: &CataContext,
    lab_name: &str,
    store_name: &str,
    data: &PlainStore,
) -> Result<()> {
    crate::io::process::check_tool("sops")?;

    let path = crate::io::secrets::store_file_path(ctx, lab_name, store_name);
    if let Some(parent) = path.parent() {
        crate::io::fs::create_dir_all(parent).context("Failed to create secrets directory")?;
    }

    let plaintext_dir = crate::io::fs::secure_tempdir()?;
    let plaintext_path = plaintext_dir.path().join("store.yaml");
    crate::io::fs::write(&plaintext_path, serde_yaml::to_string(data)?.as_bytes())?;
    crate::io::fs::set_mode(&plaintext_path, 0o600)?;

    crate::io::sops::encrypt_store(
        &plaintext_path,
        &format!("secrets/{lab_name}/{store_name}.enc.yaml"),
        &path,
        &PathBuf::from(ctx.flake_uri()),
    )
    .with_context(|| format!("encrypting store '{store_name}'"))
}

fn init_intermediate(
    ctx: &CataContext,
    name: &str,
    root: Option<&str>,
    days: u32,
    force: bool,
) -> Result<()> {
    let lab = get_lab_secrets(ctx, None)?;
    let spec = &lab.spec;

    let intermediate = spec.managed.get(name).ok_or_else(|| {
        anyhow::anyhow!(
            "'{name}' is not declared in lab.secrets.managed. Declare it with kind = \"ca\" \
             in the same store as the root."
        )
    })?;
    if intermediate.kind != SecretKind::Ca {
        bail!("'{name}' is declared with kind = \"value\", so it cannot hold a CA");
    }

    let store_name = intermediate.store.clone();
    let root_name = resolve_root_ca(spec, &store_name, name, root)?;

    let mut values = crate::io::secrets::load_store(ctx, &lab.lab_name, &store_name, spec)?;

    if values.contains_key(name) && !force {
        bail!(
            "'{name}' is already in store '{store_name}'. Pass --force to rotate it; every leaf \
             it signed is reissued on the next `cata lab up`."
        );
    }

    let root_values = values.get(&root_name).ok_or_else(|| {
        anyhow::anyhow!(
            "root CA '{root_name}' is not in store '{store_name}' yet. {}",
            describe_store_problems(
                spec,
                &lab.lab_name,
                &store_name,
                &[StoreProblem::MissingSecret {
                    secret: root_name.clone()
                }]
            )
        )
    })?;

    let root_ca = pki::CaPem {
        cert_pem: pem_of(root_values, &root_name, pki::CERT_KEY)?,
        key_pem: pem_of(root_values, &root_name, pki::KEY_KEY)?,
    };

    let signed = pki::intermediate_ca(
        &root_ca,
        &intermediate_common_name(&lab.lab_name),
        CA_ALGORITHM,
        days,
    )?;

    println!(
        "{} Signed '{name}' with root '{root_name}' ({days} days, {CA_ALGORITHM})",
        style(">>>").green(),
    );

    values.insert(
        name.to_string(),
        HashMap::from([
            (pki::CERT_KEY.to_string(), signed.cert_pem),
            (pki::KEY_KEY.to_string(), signed.key_pem),
        ]),
    );

    let sorted: PlainStore = values
        .into_iter()
        .map(|(secret, keys)| (secret, keys.into_iter().collect()))
        .collect();

    match spec.backend_of(&store_name) {
        Backend::Sops => {
            write_sops_store(ctx, &lab.lab_name, &store_name, &sorted)?;
            println!(
                "{} Wrote store '{}' at {}",
                style(">>>").green(),
                store_name,
                crate::io::secrets::store_file_path(ctx, &lab.lab_name, &store_name).display(),
            );
        }
        _ => {
            println!();
            print_env_store(&store_name, &sorted);
        }
    }

    Ok(())
}

fn resolve_root_ca(
    spec: &SecretsSpec,
    store_name: &str,
    intermediate: &str,
    override_name: Option<&str>,
) -> Result<String> {
    if let Some(name) = override_name {
        if name == intermediate {
            bail!("the root and the intermediate must be different secrets");
        }
        return Ok(name.to_string());
    }

    let candidates: Vec<&str> = spec
        .secrets_in(store_name)
        .into_iter()
        .filter(|(name, secret)| secret.kind == SecretKind::Ca && *name != intermediate)
        .map(|(name, _)| name)
        .collect();

    match candidates.as_slice() {
        [only] => Ok((*only).to_string()),
        [] => bail!(
            "store '{store_name}' holds no other kind = \"ca\" secret to sign '{intermediate}' with"
        ),
        many => bail!(
            "store '{store_name}' holds {} CAs besides '{intermediate}' ({}). \
             Pass --root to say which one signs.",
            many.len(),
            many.join(", "),
        ),
    }
}

fn pem_of(values: &HashMap<String, String>, secret: &str, key: &str) -> Result<String> {
    let value = values
        .get(key)
        .ok_or_else(|| anyhow::anyhow!("secret '{secret}' has no '{key}'"))?;
    if !value.contains("-----BEGIN") {
        bail!("'{key}' of secret '{secret}' is not PEM");
    }
    Ok(value.clone())
}

fn mint(generator: Option<&str>, length: Option<u64>, minting: Minting) -> Result<String> {
    match generator {
        None => Ok(secrets::PLACEHOLDER.to_string()),
        Some(generator) if minting.is_example() => Ok(match length {
            Some(len) => format!("<{generator}:{len}>"),
            None => format!("<{generator}>"),
        }),
        Some(generator) => generators::generate_value(generator, length),
    }
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', r"'\''"))
}

fn list(ctx: &CataContext, cluster: Option<&str>) -> Result<()> {
    let lab = get_lab_secrets(ctx, cluster)?;

    println!(
        "{} Secrets for lab '{}'",
        style("catallaxy").cyan().bold(),
        lab.lab_name,
    );
    println!();

    if !lab.spec.stores.is_empty() {
        println!("{}", style("Stores:").bold());
        for (name, store) in &lab.spec.stores {
            println!(
                "  {} ({}) → {}",
                style(name).bold(),
                store.backend.as_str(),
                store_status(ctx, &lab, name),
            );
        }
        if let Some(file) = lab.spec.env_file.as_deref() {
            println!("  envFile: {file}");
        }
        println!();
    }

    if !lab.spec.managed.is_empty() {
        println!("{}", style("Managed secrets:").bold());
        for (name, secret) in &lab.spec.managed {
            let from_env = lab.spec.backend_of(&secret.store) == Backend::Env;
            let key_list: String = secret
                .keys
                .iter()
                .map(|(key, def)| {
                    let source = match secret.kind {
                        SecretKind::Ca => "minted with the CA",
                        SecretKind::Value => def.generator.as_deref().unwrap_or("manual"),
                    };
                    if from_env {
                        format!(
                            "{key} ({source}) → {}",
                            env_var_name(&secret.store, name, key)
                        )
                    } else {
                        format!("{key} ({source})")
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

    if lab.spec.stores.is_empty() && lab.spec.managed.is_empty() {
        println!("  (none)");
    }

    Ok(())
}

fn store_status(ctx: &CataContext, lab: &LabSecrets, store_name: &str) -> String {
    match lab.spec.backend_of(store_name) {
        Backend::Sops => {
            let path = crate::io::secrets::store_file_path(ctx, &lab.lab_name, store_name);
            let status = if path.exists() {
                style("generated").green()
            } else {
                style("missing").red()
            };
            format!("{} [{}]", path.display(), status)
        }
        Backend::Env => {
            let bindings = lab.spec.env_bindings(store_name);
            let values = crate::io::secrets::read_env_store(&bindings);
            let set = values.values().map(|keys| keys.len()).sum::<usize>();
            let status = if set == bindings.len() {
                style(format!("{set} set")).green()
            } else {
                style(format!("{set} of {} set", bindings.len())).red()
            };
            format!(
                "{} variable(s) from the environment [{}]",
                bindings.len(),
                status,
            )
        }
        backend => format!("managed outside catallaxy ({})", backend.as_str()),
    }
}

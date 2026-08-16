use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use clap::Subcommand;
use console::style;
use rcgen::{CertificateParams, DistinguishedName, DnType, DnValue, IsCa, KeyUsagePurpose};
use time::{Duration, OffsetDateTime};

use crate::config::Context as CataContext;
use crate::io::pki::KeyAlgorithm;
use rcgen::KeyPair;

const PKI_CLUSTER_HELP: &str = "Cluster to act on. Defaults to the flake fragment";
const USER_HELP: &str = "User to act on, declared in the cluster's apiserver.pki.users";

#[derive(Subcommand)]
pub enum PkiCommands {
    #[command(about = "Initialize the cluster's client CA")]
    Init {
        #[arg(help = PKI_CLUSTER_HELP)]
        name: Option<String>,

        #[arg(long, help = "Replace an existing CA")]
        force: bool,
    },

    #[command(about = "Issue a client certificate for a user")]
    Issue {
        #[arg(help = USER_HELP)]
        user: String,

        #[arg(long, value_name = "NAME", help = PKI_CLUSTER_HELP)]
        cluster: Option<String>,

        #[arg(long, help = "Reissue even if a certificate already exists")]
        force: bool,
    },

    #[command(about = "Write a user's certificate to a YubiKey PIV slot")]
    Provision {
        #[arg(help = USER_HELP)]
        user: String,

        #[arg(long, value_name = "NAME", help = PKI_CLUSTER_HELP)]
        cluster: Option<String>,
    },

    #[command(about = "Show CA and certificate status")]
    List {
        #[arg(help = PKI_CLUSTER_HELP)]
        name: Option<String>,
    },

    #[command(about = "Generate a kubeconfig entry for a user's certificate")]
    Kubeconfig {
        #[arg(help = USER_HELP)]
        user: String,

        #[arg(long, value_name = "NAME", help = PKI_CLUSTER_HELP)]
        cluster: Option<String>,

        #[arg(
            long,
            short,
            value_name = "PATH",
            help = "Where to write the kubeconfig. Defaults to stdout"
        )]
        output: Option<String>,
    },
}

pub async fn run(ctx: &CataContext, command: PkiCommands) -> Result<()> {
    match command {
        PkiCommands::Init { name, force } => {
            let name = ctx.resolve_cluster_name(name.as_deref())?;
            init(ctx, &name, force).await
        }
        PkiCommands::Issue {
            user,
            cluster,
            force,
        } => {
            let name = ctx.resolve_cluster_name(cluster.as_deref())?;
            issue(ctx, &name, &user, force).await
        }
        PkiCommands::Provision { user, cluster } => {
            let name = ctx.resolve_cluster_name(cluster.as_deref())?;
            provision(ctx, &name, &user).await
        }
        PkiCommands::List { name } => {
            let name = ctx.resolve_cluster_name(name.as_deref())?;
            list(ctx, &name).await
        }
        PkiCommands::Kubeconfig {
            user,
            cluster,
            output,
        } => {
            let name = ctx.resolve_cluster_name(cluster.as_deref())?;
            kubeconfig(ctx, &name, &user, output).await
        }
    }
}

fn pki_dir(cluster_name: &str) -> PathBuf {
    crate::host::state::cluster_pki_dir(cluster_name)
}

fn ca_key_path(cluster_name: &str) -> PathBuf {
    pki_dir(cluster_name).join("ca.key")
}

fn ca_cert_path(cluster_name: &str) -> PathBuf {
    pki_dir(cluster_name).join("ca.crt")
}

fn user_dir(cluster_name: &str, user: &str) -> PathBuf {
    pki_dir(cluster_name).join("users").join(user)
}

fn user_key_path(cluster_name: &str, user: &str) -> PathBuf {
    user_dir(cluster_name, user).join(format!("{user}.key"))
}

fn user_cert_path(cluster_name: &str, user: &str) -> PathBuf {
    user_dir(cluster_name, user).join(format!("{user}.crt"))
}

fn get_pki_config(ctx: &CataContext, cluster_name: &str) -> Result<serde_json::Value> {
    let config = crate::io::nix::get_cluster_config(ctx, cluster_name)?;
    let pki = config
        .pointer("/apiserver/pki")
        .cloned()
        .unwrap_or_default();

    if !pki["enable"].as_bool().unwrap_or(false) {
        bail!(
            "PKI auth is not enabled on cluster '{cluster_name}'. \
             Set cluster.apiserver.pki.enable = true;"
        );
    }

    Ok(pki)
}

fn parse_validity(s: &str) -> Result<u32> {
    let s = s.trim();
    if let Some(years) = s.strip_suffix('y') {
        Ok(years.parse::<u32>().context("invalid year count")? * 365)
    } else if let Some(days) = s.strip_suffix('d') {
        Ok(days.parse::<u32>().context("invalid day count")?)
    } else if let Some(hours) = s.strip_suffix('h') {
        Ok(hours.parse::<u32>().context("invalid hour count")? / 24)
    } else {
        bail!("unsupported validity format: {s} (use Ny, Nd, or Nh)");
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UserCertSpec {
    pub common_name: String,
    pub organizations: Vec<String>,
    pub algorithm: KeyAlgorithm,
    pub validity: String,
    pub validity_days: u32,
}

const DEFAULT_ALGORITHM: &str = "ecdsa-p256";
const DEFAULT_VALIDITY: &str = "1y";

fn resolve_user(
    pki: &serde_json::Value,
    user_config: &serde_json::Value,
    user: &str,
) -> Result<UserCertSpec> {
    let default = |field: &str| {
        pki.pointer(&format!("/out/pki/defaults/{field}"))
            .and_then(|v| v.as_str())
    };
    let layered = |field: &str, fallback: &'static str| {
        user_config[field]
            .as_str()
            .or_else(|| default(field))
            .unwrap_or(fallback)
            .to_string()
    };

    let validity = layered("validity", DEFAULT_VALIDITY);

    Ok(UserCertSpec {
        common_name: user_config["commonName"]
            .as_str()
            .unwrap_or(user)
            .to_string(),
        organizations: user_config["organizations"]
            .as_array()
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default(),
        algorithm: KeyAlgorithm::parse(&layered("keyAlgorithm", DEFAULT_ALGORITHM))?,
        validity_days: parse_validity(&validity)?,
        validity,
    })
}

async fn init(ctx: &CataContext, cluster_name: &str, force: bool) -> Result<()> {
    let pki = get_pki_config(ctx, cluster_name)?;

    let ca_key = ca_key_path(cluster_name);
    let ca_cert = ca_cert_path(cluster_name);

    if ca_key.exists() && !force {
        println!(
            "{} CA already exists at {}",
            style(">>>").green(),
            pki_dir(cluster_name).display()
        );
        println!("  Use --force to re-create");
        return Ok(());
    }

    let cn = pki
        .pointer("/ca/commonName")
        .and_then(|v| v.as_str())
        .unwrap_or("catallaxy-ca");

    let algorithm = KeyAlgorithm::parse(
        pki.pointer("/ca/keyAlgorithm")
            .and_then(|v| v.as_str())
            .unwrap_or(DEFAULT_ALGORITHM),
    )?;

    let validity_str = pki
        .pointer("/ca/validity")
        .and_then(|v| v.as_str())
        .unwrap_or("10y");

    let validity_days = parse_validity(validity_str)?;

    println!(
        "{} Initializing CA for cluster '{cluster_name}'",
        style(">>>").cyan()
    );
    println!("  CN:        {cn}");
    println!("  Algorithm: {algorithm}");
    println!("  Validity:  {validity_str} ({validity_days} days)");

    // The same mint the lab's own CA goes through. This used to repeat the
    // rcgen parameters inline and the two copies had drifted: this one left
    // out DigitalSignature, so a CA depended on which command made it.
    let ca = crate::io::pki::self_signed_ca(cn, algorithm, validity_days)?;

    let dir = pki_dir(cluster_name);
    crate::io::fs::create_dir_all(&dir)
        .with_context(|| format!("Failed to create {}", dir.display()))?;

    crate::io::fs::write(&ca_key, &ca.key_pem)
        .with_context(|| format!("Failed to write {}", ca_key.display()))?;
    crate::io::fs::write(&ca_cert, &ca.cert_pem)
        .with_context(|| format!("Failed to write {}", ca_cert.display()))?;

    #[cfg(unix)]
    {
        crate::io::fs::set_mode(&ca_key, 0o600)?;
    }

    println!("{} CA created at {}", style(">>>").green(), dir.display());
    println!("  Key:  {}", ca_key.display());
    println!("  Cert: {}", ca_cert.display());

    Ok(())
}

async fn issue(ctx: &CataContext, cluster_name: &str, user: &str, force: bool) -> Result<()> {
    let pki = get_pki_config(ctx, cluster_name)?;

    let ca_key_file = ca_key_path(cluster_name);
    let ca_cert_file = ca_cert_path(cluster_name);
    if !ca_key_file.exists() || !ca_cert_file.exists() {
        bail!("CA not initialized for cluster '{cluster_name}'. Run `cata pki init` first.");
    }

    let user_config = pki
        .pointer(&format!("/out/pki/users/{user}"))
        .ok_or_else(|| {
            anyhow::anyhow!(
                "User '{user}' not found in pki-auth.users for cluster '{cluster_name}'"
            )
        })?;

    let cert_path = user_cert_path(cluster_name, user);
    if cert_path.exists() && !force {
        println!(
            "{} Certificate already exists for '{user}' at {}",
            style(">>>").green(),
            cert_path.display()
        );
        println!("  Use --force to re-issue");
        return Ok(());
    }

    let UserCertSpec {
        common_name: cn,
        organizations,
        algorithm,
        validity,
        validity_days,
    } = resolve_user(&pki, user_config, user)?;

    println!(
        "{} Issuing certificate for '{user}' on cluster '{cluster_name}'",
        style(">>>").cyan()
    );
    println!("  CN:            {cn}");
    println!("  Organizations: {}", organizations.join(", "));
    println!("  Algorithm:     {algorithm}");
    println!("  Validity:      {validity} ({validity_days} days)");

    let ca_key_pem = crate::io::fs::read_to_string(&ca_key_file)?;
    let ca_cert_pem = crate::io::fs::read_to_string(&ca_cert_file)?;

    let ca_key_pair = KeyPair::from_pem(&ca_key_pem)?;
    let ca_params = CertificateParams::from_ca_cert_pem(&ca_cert_pem)
        .map_err(|e| anyhow::anyhow!("Failed to parse CA cert: {e}"))?;
    let ca_cert = ca_params.self_signed(&ca_key_pair)?;

    let user_key_pair = crate::io::pki::key_pair(algorithm)?;

    let mut params = CertificateParams::default();
    params.distinguished_name = DistinguishedName::new();
    params
        .distinguished_name
        .push(DnType::CommonName, DnValue::Utf8String(cn.to_string()));
    for org in &organizations {
        params
            .distinguished_name
            .push(DnType::OrganizationName, DnValue::Utf8String(org.clone()));
    }
    params.is_ca = IsCa::NoCa;
    params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
    params.extended_key_usages = vec![rcgen::ExtendedKeyUsagePurpose::ClientAuth];
    params.not_before = OffsetDateTime::now_utc();
    params.not_after = OffsetDateTime::now_utc() + Duration::days(validity_days as i64);

    let user_cert = params.signed_by(&user_key_pair, &ca_cert, &ca_key_pair)?;

    let dir = user_dir(cluster_name, user);
    crate::io::fs::create_dir_all(&dir)?;

    let key_path = user_key_path(cluster_name, user);
    crate::io::fs::write(&key_path, user_key_pair.serialize_pem())?;
    crate::io::fs::write(&cert_path, user_cert.pem())?;

    #[cfg(unix)]
    {
        crate::io::fs::set_mode(&key_path, 0o600)?;
    }

    println!("{} Certificate issued for '{user}'", style(">>>").green());
    println!("  Key:  {}", key_path.display());
    println!("  Cert: {}", cert_path.display());

    Ok(())
}

async fn provision(_ctx: &CataContext, cluster_name: &str, user: &str) -> Result<()> {
    let pki_config = get_pki_config(_ctx, cluster_name)?;

    let user_config = pki_config
        .pointer(&format!("/out/pki/users/{user}"))
        .ok_or_else(|| anyhow::anyhow!("User '{user}' not found in pki-auth.users"))?;

    let slot = user_config
        .pointer("/yubikey/slot")
        .and_then(|v| v.as_str())
        .unwrap_or("9a");

    let touch_policy = user_config
        .pointer("/yubikey/touchPolicy")
        .and_then(|v| v.as_str())
        .unwrap_or("always");

    let pin_policy = user_config
        .pointer("/yubikey/pinPolicy")
        .and_then(|v| v.as_str())
        .unwrap_or("once");

    let serial = user_config
        .pointer("/yubikey/serialNumber")
        .and_then(|v| v.as_str());

    let key_path = user_key_path(cluster_name, user);
    let cert_path = user_cert_path(cluster_name, user);

    if !key_path.exists() || !cert_path.exists() {
        bail!("Certificate not found for '{user}'. Run `cata pki issue {user}` first.");
    }

    which::which("ykman").context(
        "ykman not found. Install it: brew install ykman (macOS) or pip install yubikey-manager",
    )?;

    println!(
        "{} Provisioning certificate for '{user}' to YubiKey",
        style(">>>").cyan()
    );
    println!("  Slot:         {slot}");
    println!("  Touch policy: {touch_policy}");
    println!("  PIN policy:   {pin_policy}");
    if let Some(s) = serial {
        println!("  Serial:       {s}");
    }

    crate::io::ykman::import_key(slot, &key_path, pin_policy, touch_policy, serial)?;
    crate::io::ykman::import_certificate(slot, &cert_path, serial)?;

    println!(
        "{} Certificate provisioned to YubiKey slot {slot}",
        style(">>>").green()
    );

    Ok(())
}

async fn list(ctx: &CataContext, cluster_name: &str) -> Result<()> {
    let pki = get_pki_config(ctx, cluster_name)?;

    println!(
        "{} PKI status for cluster '{cluster_name}'",
        style("catallaxy").cyan().bold()
    );
    println!();

    let dir = pki_dir(cluster_name);
    let ca_cert = ca_cert_path(cluster_name);

    if ca_cert.exists() {
        let pem_data = crate::io::fs::read_to_string(&ca_cert)?;
        let (_, parsed) = x509_parser::pem::parse_x509_pem(pem_data.as_bytes())
            .map_err(|e| anyhow::anyhow!("Failed to parse CA cert: {e}"))?;
        let cert = parsed
            .parse_x509()
            .map_err(|e| anyhow::anyhow!("Failed to parse X509: {e}"))?;

        let cn = cert
            .subject()
            .iter_common_name()
            .next()
            .map(|cn| cn.as_str().unwrap_or("?"))
            .unwrap_or("?");
        let not_after = cert.validity().not_after;

        println!(
            "  {} CA: {} (expires {})",
            style("✓").green(),
            cn,
            not_after
        );
    } else {
        println!(
            "  {} CA: {} (run `cata pki init`)",
            style("✗").red(),
            style("not initialized").red()
        );
    }

    let users = pki
        .pointer("/out/pki/users")
        .and_then(|v| v.as_object())
        .cloned()
        .unwrap_or_default();

    if !users.is_empty() {
        println!();
        println!("{}", style("  Users:").bold());
    }

    for (user_name, user_config) in &users {
        let cert_path = user_cert_path(cluster_name, user_name);
        let cn = user_config["commonName"].as_str().unwrap_or("?");
        let orgs: Vec<&str> = user_config["organizations"]
            .as_array()
            .map(|arr| arr.iter().filter_map(|v| v.as_str()).collect())
            .unwrap_or_default();

        let yubikey_serial = user_config
            .pointer("/yubikey/serialNumber")
            .and_then(|v| v.as_str());

        if cert_path.exists() {
            let pem_data = crate::io::fs::read_to_string(&cert_path)?;
            let (_, parsed) = x509_parser::pem::parse_x509_pem(pem_data.as_bytes())
                .map_err(|e| anyhow::anyhow!("Failed to parse cert: {e}"))?;
            let cert = parsed
                .parse_x509()
                .map_err(|e| anyhow::anyhow!("Failed to parse X509: {e}"))?;

            let not_after = cert.validity().not_after;
            let yubikey_str = yubikey_serial
                .map(|s| format!(" [YubiKey: {s}]"))
                .unwrap_or_default();

            println!(
                "    {} {}: CN={}, O=[{}], expires {}{}",
                style("✓").green(),
                style(user_name).bold(),
                cn,
                orgs.join(", "),
                not_after,
                yubikey_str
            );
        } else {
            println!(
                "    {} {}: CN={}, O=[{}] (run `cata pki issue {}`)",
                style("✗").yellow(),
                style(user_name).bold(),
                cn,
                orgs.join(", "),
                user_name
            );
        }
    }

    println!();
    println!("  PKI dir: {}", dir.display());

    Ok(())
}

async fn kubeconfig(
    ctx: &CataContext,
    cluster_name: &str,
    user: &str,
    output: Option<String>,
) -> Result<()> {
    let pki = get_pki_config(ctx, cluster_name)?;

    let user_config = pki
        .pointer(&format!("/out/pki/users/{user}"))
        .ok_or_else(|| anyhow::anyhow!("User '{user}' not found in pki-auth.users"))?;

    let cn = user_config["commonName"].as_str().unwrap_or(user);

    let cert_path = user_cert_path(cluster_name, user);
    let key_path = user_key_path(cluster_name, user);
    let ca_cert = ca_cert_path(cluster_name);

    if !cert_path.exists() || !key_path.exists() {
        bail!("Certificate not found for '{user}'. Run `cata pki issue {user}` first.");
    }
    if !ca_cert.exists() {
        bail!("CA not found. Run `cata pki init` first.");
    }

    let cert_data = base64::Engine::encode(
        &base64::engine::general_purpose::STANDARD,
        crate::io::fs::read(&cert_path)?,
    );
    let key_data = base64::Engine::encode(
        &base64::engine::general_purpose::STANDARD,
        crate::io::fs::read(&key_path)?,
    );
    let ca_data = base64::Engine::encode(
        &base64::engine::general_purpose::STANDARD,
        crate::io::fs::read(&ca_cert)?,
    );

    let cluster_config = crate::io::nix::get_cluster_config(ctx, cluster_name)?;
    let k3d_name = cluster_config
        .pointer("/provisionerConfig/k3d/clusterName")
        .and_then(|v| v.as_str())
        .unwrap_or(cluster_name);
    let _context_name = format!("k3d-{k3d_name}");

    let kubeconfig = serde_json::json!({
        "apiVersion": "v1",
        "kind": "Config",
        "clusters": [{
            "cluster": {
                "certificate-authority-data": ca_data,
                "server": format!("https://0.0.0.0:6443")
            },
            "name": cluster_name
        }],
        "contexts": [{
            "context": {
                "cluster": cluster_name,
                "user": cn
            },
            "name": format!("{cluster_name}-{user}")
        }],
        "current-context": format!("{cluster_name}-{user}"),
        "users": [{
            "name": cn,
            "user": {
                "client-certificate-data": cert_data,
                "client-key-data": key_data
            }
        }]
    });

    let yaml = serde_yaml::to_string(&kubeconfig)?;

    let output_display = output.as_deref().unwrap_or("<file>").to_string();

    match output {
        Some(path) => {
            crate::io::fs::write(&path, &yaml)?;
            println!("{} Kubeconfig written to {}", style(">>>").green(), path);
        }
        None => {
            print!("{yaml}");
        }
    }

    println!("\n  {} Merge into your kubeconfig:", style("Tip:").bold());
    println!(
        "    KUBECONFIG=~/.kube/config:{} kubectl config view --flatten > ~/.kube/config.merged",
        output_display
    );
    println!("    kubectl --context {cluster_name}-{user} get pods");

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn pki_with_defaults(defaults: serde_json::Value) -> serde_json::Value {
        json!({ "out": { "pki": { "defaults": defaults } } })
    }

    #[test]
    fn a_user_without_overrides_takes_the_cluster_defaults() {
        let pki = pki_with_defaults(json!({ "keyAlgorithm": "ecdsa-p384", "validity": "30d" }));

        let spec = resolve_user(&pki, &json!({}), "alice").expect("resolves");

        assert_eq!(spec.algorithm.as_str(), "ecdsa-p384");
        assert_eq!(spec.validity, "30d");
        assert_eq!(spec.validity_days, 30);
    }

    #[test]
    fn a_user_override_wins_over_the_default() {
        let pki = pki_with_defaults(json!({ "keyAlgorithm": "ecdsa-p384", "validity": "30d" }));
        let user = json!({ "keyAlgorithm": "ecdsa-p256", "validity": "2y" });

        let spec = resolve_user(&pki, &user, "alice").expect("resolves");

        assert_eq!(spec.algorithm.as_str(), "ecdsa-p256");
        assert_eq!(spec.validity_days, 730);
    }

    #[test]
    fn a_lab_declaring_nothing_still_gets_a_usable_spec() {
        let spec = resolve_user(&json!({}), &json!({}), "alice").expect("resolves");

        assert_eq!(spec.algorithm.as_str(), DEFAULT_ALGORITHM);
        assert_eq!(spec.validity, DEFAULT_VALIDITY);
        assert_eq!(spec.validity_days, 365);
    }

    #[test]
    fn the_common_name_falls_back_to_the_user_key() {
        let named = resolve_user(
            &json!({}),
            &json!({ "commonName": "a@example.com" }),
            "alice",
        )
        .expect("resolves");
        assert_eq!(named.common_name, "a@example.com");

        let unnamed = resolve_user(&json!({}), &json!({}), "alice").expect("resolves");
        assert_eq!(
            unnamed.common_name, "alice",
            "the username is the identity the apiserver sees when nothing else is said"
        );
    }

    #[test]
    fn organizations_become_the_users_groups_and_default_to_none() {
        let with = resolve_user(
            &json!({}),
            &json!({ "organizations": ["admins", "sre"] }),
            "alice",
        )
        .expect("resolves");
        assert_eq!(with.organizations, vec!["admins", "sre"]);

        let without = resolve_user(&json!({}), &json!({}), "alice").expect("resolves");
        assert!(without.organizations.is_empty());
    }

    #[test]
    fn a_validity_the_parser_does_not_understand_is_an_error() {
        let user = json!({ "validity": "forever" });
        assert!(resolve_user(&json!({}), &user, "alice").is_err());
    }

    #[test]
    fn validity_units_convert_the_way_the_parser_says() {
        assert_eq!(parse_validity("1y").expect("y"), 365);
        assert_eq!(parse_validity("90d").expect("d"), 90);
        assert_eq!(parse_validity("48h").expect("h"), 2);
        assert!(parse_validity("1w").is_err());
        assert!(parse_validity("").is_err());
    }
}

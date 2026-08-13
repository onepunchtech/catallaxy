use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use anyhow::{Context, Result, bail};
use console::style;

use crate::config::Context as CataContext;
use crate::domain::LabSpec;
use crate::host::state::service_state_dir;
use crate::io::process::run_capture;

pub fn ensure_ingress_cert(lab_name: &str, zone: &str) -> Result<PathBuf> {
    let ingress_dir = service_state_dir(lab_name, "proxy");
    let cert_pem = ingress_dir.join("lab.pem");
    if cert_pem.exists() {
        return Ok(ingress_dir);
    }
    fs::create_dir_all(&ingress_dir)?;

    let ca_cert = ingress_dir.join("ca.crt");
    let ca_key = ingress_dir.join("ca.key");

    if !(ca_cert.exists() && ca_key.exists()) {
        println!(
            "{} No stored CA on disk. Minting a local one. Declare a \
             `kind = \"ca\"` managed secret and run `cata secrets generate` \
             to share one across the team.",
            style(">>>").yellow(),
        );
        mint_local_ca(&ca_cert, &ca_key)?;
    } else {
        println!(
            "{} Using existing lab CA at {}",
            style(">>>").green(),
            ca_cert.display(),
        );
    }

    sign_server_cert(&ingress_dir, &ca_cert, &ca_key, &cert_pem, zone)?;

    println!(
        "{} TLS certificate ready at {}",
        style(">>>").green(),
        ingress_dir.display(),
    );

    Ok(ingress_dir)
}

fn mint_local_ca(ca_cert: &Path, ca_key: &Path) -> Result<()> {
    let status = Command::new("openssl")
        .args(["genrsa", "-out"])
        .arg(ca_key)
        .arg("4096")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .context("Failed to run openssl genrsa for CA")?;
    if !status.success() {
        bail!("Failed to generate CA key");
    }

    let status = Command::new("openssl")
        .args(["req", "-new", "-x509", "-key"])
        .arg(ca_key)
        .args(["-out"])
        .arg(ca_cert)
        .args(["-days", "3650", "-subj", "/CN=Catallaxy Lab CA"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .context("Failed to run openssl req for CA")?;
    if !status.success() {
        bail!("Failed to generate CA certificate");
    }
    Ok(())
}

pub fn ensure_host_trust(lab_name: &str, ca_path: &Path) -> Result<()> {
    if !ca_path.exists() {
        return Ok(());
    }

    if cfg!(target_os = "macos") {
        ensure_host_trust_macos(lab_name, ca_path)
    } else {
        ensure_host_trust_linux(lab_name, ca_path)
    }
}

fn ensure_host_trust_macos(_lab_name: &str, ca_path: &Path) -> Result<()> {
    let disk_fp = {
        let out = Command::new("openssl")
            .args(["x509", "-in"])
            .arg(ca_path)
            .args(["-noout", "-fingerprint", "-sha1"])
            .output()
            .context("Failed to run openssl x509 fingerprint")?;
        let s = String::from_utf8_lossy(&out.stdout).to_string();
        s.split('=')
            .nth(1)
            .unwrap_or("")
            .trim()
            .replace(':', "")
            .to_uppercase()
    };

    if disk_fp.is_empty() {
        bail!(
            "Could not compute SHA-1 fingerprint of {}",
            ca_path.display()
        );
    }

    let keychain_fp = {
        let out = Command::new("security")
            .args([
                "find-certificate",
                "-c",
                "Catallaxy Lab CA",
                "-a",
                "-Z",
                "/Library/Keychains/System.keychain",
            ])
            .output();

        match out {
            Ok(o) if o.status.success() => {
                let s = String::from_utf8_lossy(&o.stdout).to_string();
                s.lines()
                    .find(|l| l.starts_with("SHA-1 hash:"))
                    .map(|l| l.trim_start_matches("SHA-1 hash:").trim().to_uppercase())
                    .unwrap_or_default()
            }
            _ => String::new(),
        }
    };

    if keychain_fp == disk_fp {
        println!(
            "{} Lab CA already trusted (System keychain)",
            style(">>>").green()
        );
        return Ok(());
    }

    if !keychain_fp.is_empty() {
        println!(
            "{} Lab CA changed, updating System keychain trust",
            style(">>>").cyan()
        );
    } else {
        println!(
            "{} Installing lab CA into System keychain",
            style(">>>").cyan()
        );
    }
    println!(
        "    This requires sudo + macOS admin credentials to modify\n    \
         the System keychain."
    );

    let status = Command::new("sudo")
        .args([
            "security",
            "add-trusted-cert",
            "-d",
            "-r",
            "trustRoot",
            "-k",
            "/Library/Keychains/System.keychain",
        ])
        .arg(ca_path)
        .status()
        .context("Failed to run sudo security add-trusted-cert")?;

    if !status.success() {
        bail!("Failed to install lab CA into System keychain");
    }

    println!("{} Lab CA trusted", style(">>>").green());
    Ok(())
}

fn ensure_host_trust_linux(lab_name: &str, ca_path: &Path) -> Result<()> {
    if Path::new("/etc/NIXOS").exists() {
        const BUNDLE: &str = "/etc/ssl/certs/ca-certificates.crt";
        let ca_pem = fs::read_to_string(ca_path)
            .with_context(|| format!("reading lab CA at {}", ca_path.display()))?;

        match fs::read_to_string(BUNDLE) {
            Ok(bundle) if bundle.contains(ca_pem.trim()) => {
                println!(
                    "{} Lab CA trusted (NixOS system bundle)",
                    style(">>>").green()
                );
                Ok(())
            }
            Ok(_) => {
                bail!(
                    "Lab CA for '{lab_name}' is not in the NixOS system trust store, \
                     and this lab set `lab.trust.installIntoHostStore = true`.\n\
                     \n    Either add to your NixOS configuration:\n\
                     \n      security.pki.certificateFiles = [ \"{}\" ];\n\
                     \n    then: sudo nixos-rebuild switch\n\
                     \n    Or drop the option back to its default (false), which \
                     needs no host changes at all: `cata` hands every tool it \
                     spawns a merged CA bundle, `nix develop` on the lab gives \
                     your shell the same trust, and `eval \"$(cata lab env \
                     {lab_name})\"` does it for a shell you are already in.\n\
                     \n    Browsers read neither — for those, \
                     `cata lab ops -- trust setup` imports into your NSS store \
                     without sudo.",
                    ca_path.display(),
                )
            }
            Err(e) => {
                println!(
                    "{} NixOS detected but {BUNDLE} is unreadable ({e}); \
                     cannot verify lab CA trust. If HTTPS to *.<zone> fails, add:\n    \
                     security.pki.certificateFiles = [ \"{}\" ];",
                    style("Warning:").yellow(),
                    ca_path.display(),
                );
                Ok(())
            }
        }
    } else {
        ensure_host_trust_linux_writable(lab_name, ca_path)
    }
}

fn ensure_host_trust_linux_writable(lab_name: &str, ca_path: &Path) -> Result<()> {
    let dest = format!("/usr/local/share/ca-certificates/catallaxy-{lab_name}.crt");

    if Path::new(&dest).exists() {
        let installed = fs::read(&dest).unwrap_or_default();
        let current = fs::read(ca_path).unwrap_or_default();
        if installed == current {
            println!(
                "{} Lab CA already in system trust store",
                style(">>>").green()
            );
            return Ok(());
        }
        println!(
            "{} Lab CA changed, updating system trust store",
            style(">>>").cyan()
        );
    } else {
        println!(
            "{} Installing lab CA into system trust store",
            style(">>>").cyan()
        );
    }

    println!("    This requires sudo to install into /usr/local/share/ca-certificates/");

    let status = Command::new("sudo")
        .args(["install", "-m", "0644"])
        .arg(ca_path)
        .arg(&dest)
        .status()
        .context("Failed to install CA cert")?;

    if !status.success() {
        bail!("Failed to install lab CA");
    }

    if which::which("update-ca-certificates").is_ok() {
        let _ = Command::new("sudo")
            .args(["update-ca-certificates"])
            .status();
    }

    println!("{} Lab CA trusted", style(">>>").green());
    Ok(())
}

fn sign_server_cert(
    ingress_dir: &Path,
    ca_cert: &Path,
    ca_key: &Path,
    cert_pem: &Path,
    zone: &str,
) -> Result<()> {
    let srv_key = ingress_dir.join("lab.key");
    let status = Command::new("openssl")
        .args(["genrsa", "-out"])
        .arg(&srv_key)
        .arg("4096")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .context("Failed to run openssl genrsa for server")?;
    if !status.success() {
        bail!("Failed to generate server key");
    }

    let srv_csr = ingress_dir.join("lab.csr");
    let san = format!("subjectAltName=DNS:*.{},DNS:{}", zone, zone);
    let status = Command::new("openssl")
        .args(["req", "-new", "-key"])
        .arg(&srv_key)
        .args(["-out"])
        .arg(&srv_csr)
        .args(["-subj", &format!("/CN=*.{}", zone), "-addext", &san])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .context("Failed to run openssl req for server CSR")?;
    if !status.success() {
        bail!("Failed to generate server CSR");
    }

    let srv_crt = ingress_dir.join("lab.crt");
    let status = Command::new("openssl")
        .args(["x509", "-req", "-in"])
        .arg(&srv_csr)
        .args(["-CA"])
        .arg(ca_cert)
        .args(["-CAkey"])
        .arg(ca_key)
        .args(["-CAcreateserial", "-out"])
        .arg(&srv_crt)
        .args(["-days", "365", "-copy_extensions", "copyall"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .context("Failed to run openssl x509 for signing")?;
    if !status.success() {
        bail!("Failed to sign server certificate");
    }

    let crt_data = fs::read_to_string(&srv_crt)?;
    let key_data = fs::read_to_string(&srv_key)?;
    fs::write(cert_pem, format!("{}{}", crt_data, key_data))?;
    Ok(())
}

pub fn import_lab_ca(
    ctx: &CataContext,
    lab_name: &str,
    lab: &LabSpec,
    cluster_name: &str,
) -> Result<()> {
    let ingress_dir = crate::host::state::service_state_dir(lab_name, "proxy");
    let ca_crt = ingress_dir.join("ca.crt");
    let ca_key = ingress_dir.join("ca.key");

    if !ca_crt.exists() || !ca_key.exists() {
        return Ok(());
    }

    let context = lab.kube_context(cluster_name)?;

    let mut namespace = Command::new("kubectl");
    namespace.args(["--context", context, "create", "namespace", "cert-manager"]);
    let _ = run_capture(&mut namespace, ctx);

    let mut delete = Command::new("kubectl");
    delete.args([
        "--context",
        context,
        "delete",
        "secret",
        "lab-ca-ca-secret",
        "-n",
        "cert-manager",
    ]);
    let _ = run_capture(&mut delete, ctx);

    let mut create = Command::new("kubectl");
    create
        .args([
            "--context",
            context,
            "create",
            "secret",
            "tls",
            "lab-ca-ca-secret",
            "-n",
            "cert-manager",
            "--cert",
        ])
        .arg(&ca_crt)
        .args(["--key"])
        .arg(&ca_key);

    match run_capture(&mut create, ctx) {
        Ok(_) => {
            println!(
                "{} Lab CA imported into '{cluster_name}'",
                style(">>>").green()
            );
        }
        Err(_) => {
            println!(
                "{} Failed to import CA into '{cluster_name}'",
                style(">>>").yellow()
            );
        }
    }

    Ok(())
}

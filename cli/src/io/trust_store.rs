use std::path::Path;
use std::process::Command;

use anyhow::{Context, Result, bail};

const SYSTEM_KEYCHAIN: &str = "/Library/Keychains/System.keychain";

pub fn keychain_certificates(common_name: &str) -> String {
    let out = Command::new("security")
        .args([
            "find-certificate",
            "-c",
            common_name,
            "-a",
            "-Z",
            SYSTEM_KEYCHAIN,
        ])
        .output();

    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).to_string(),
        _ => String::new(),
    }
}

pub fn add_trusted_root(cert: &Path) -> Result<()> {
    let status = Command::new("sudo")
        .args([
            "security",
            "add-trusted-cert",
            "-d",
            "-r",
            "trustRoot",
            "-k",
            SYSTEM_KEYCHAIN,
        ])
        .arg(cert)
        .status()
        .context("Failed to run sudo security add-trusted-cert")?;

    if !status.success() {
        bail!("Failed to install lab CA into System keychain");
    }
    Ok(())
}

pub fn install_system_certificate(cert: &Path, dest: &str) -> Result<()> {
    let status = Command::new("sudo")
        .args(["install", "-m", "0644"])
        .arg(cert)
        .arg(dest)
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
    Ok(())
}

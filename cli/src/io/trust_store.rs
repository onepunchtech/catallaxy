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

/// Trust a CA as a root in the macOS System keychain.
///
/// # Errors
///
/// If `sudo` cannot be spawned, or `security` exits non-zero because the
/// operator declined the prompt or the certificate does not parse.
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

/// Drop a CA into the Linux system trust directory and refresh the bundle.
///
/// # Errors
///
/// If `sudo` cannot be spawned, or `install` exits non-zero. The subsequent
/// `update-ca-certificates` is best effort and skipped where it is absent, so
/// success does not promise the merged bundle was rebuilt.
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

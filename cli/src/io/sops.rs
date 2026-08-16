use std::path::Path;
use std::process::{Command, Stdio};

use anyhow::{Context, Result, bail};

use crate::domain::secrets::StoreValues;

pub fn encrypt_store(
    plaintext: &Path,
    filename_override: &str,
    output: &Path,
    cwd: &Path,
) -> Result<()> {
    let status = Command::new("sops")
        .current_dir(cwd)
        .args([
            "--encrypt",
            "--input-type",
            "yaml",
            "--output-type",
            "yaml",
            "--filename-override",
            filename_override,
            "--output",
            &output.display().to_string(),
        ])
        .arg(plaintext)
        .status()
        .context("Failed to run sops encrypt")?;

    if !status.success() {
        bail!(
            "sops could not encrypt to {}. Is there a creation rule for {filename_override} in .sops.yaml?",
            output.display(),
        );
    }

    Ok(())
}

pub fn decrypt_store(path: &Path) -> Result<StoreValues> {
    let output = Command::new("sops")
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
    let data: StoreValues = serde_yaml::from_str(&yaml_str)?;
    Ok(data)
}

pub fn edit(file: &str) -> Result<std::process::ExitStatus> {
    Command::new("sops")
        .arg(file)
        .status()
        .context("Failed to run sops")
}

pub fn encrypt_to(file: &str, output: &str) -> Result<std::process::ExitStatus> {
    Command::new("sops")
        .args(["--encrypt", file, "--output", output])
        .status()
        .context("Failed to run sops")
}

pub fn decrypt_to_stdout(file: &str) -> Result<std::process::Output> {
    Command::new("sops")
        .args(["--decrypt", file])
        .output()
        .context("Failed to run sops")
}

pub fn rotate_in_place(file: &str) -> Result<std::process::ExitStatus> {
    Command::new("sops")
        .args(["rotate", "--in-place", file])
        .status()
        .context("Failed to run sops")
}

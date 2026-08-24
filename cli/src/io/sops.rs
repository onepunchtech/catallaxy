use std::path::Path;
use std::process::{Command, Stdio};

use anyhow::{Context, Result, bail};

use crate::domain::secrets::StoreValues;

/// # Errors
///
/// If `sops` cannot be spawned, or exits non-zero. The usual cause is no
/// creation rule matching `filename_override` in `.sops.yaml`, so the message
/// names it: sops picks its recipients by the path it thinks it is writing,
/// which is why the override is passed rather than the real output path.
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

/// # Errors
///
/// If `sops` cannot be spawned, exits non-zero because no key is available,
/// or produces YAML that is not a [`StoreValues`]. sops keeps stdin and stderr,
/// so a prompt for a key reaches the operator.
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

/// # Errors
///
/// Only if `sops` cannot be spawned. An abandoned edit is a non-zero
/// `ExitStatus`.
pub fn edit(file: &str) -> Result<std::process::ExitStatus> {
    Command::new("sops")
        .arg(file)
        .status()
        .context("Failed to run sops")
}

/// # Errors
///
/// Only if `sops` cannot be spawned. A missing creation rule is a non-zero
/// `ExitStatus`.
pub fn encrypt_to(file: &str, output: &str) -> Result<std::process::ExitStatus> {
    Command::new("sops")
        .args(["--encrypt", file, "--output", output])
        .status()
        .context("Failed to run sops")
}

/// # Errors
///
/// Only if `sops` cannot be spawned. A failed decrypt is a non-zero status in
/// the returned `Output`, and the plaintext, if any, is in its `stdout`.
pub fn decrypt_to_stdout(file: &str) -> Result<std::process::Output> {
    Command::new("sops")
        .args(["--decrypt", file])
        .output()
        .context("Failed to run sops")
}

/// # Errors
///
/// Only if `sops` cannot be spawned. A failed rotation is a non-zero
/// `ExitStatus`; sops leaves the file alone in that case.
pub fn rotate_in_place(file: &str) -> Result<std::process::ExitStatus> {
    Command::new("sops")
        .args(["rotate", "--in-place", file])
        .status()
        .context("Failed to run sops")
}

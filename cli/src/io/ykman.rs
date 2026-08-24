use std::path::Path;
use std::process::Command;

use anyhow::{Context, Result, bail};

/// # Errors
///
/// If `ykman` cannot be spawned, or exits non-zero. Its output goes to the
/// terminal, so a PIN or touch prompt reaches the operator and its complaint
/// is already on screen.
pub fn import_key(
    slot: &str,
    key: &Path,
    pin_policy: &str,
    touch_policy: &str,
    serial: Option<&str>,
) -> Result<()> {
    let mut cmd = Command::new("ykman");
    cmd.args(["piv", "keys", "import"]);
    cmd.args(["--pin-policy", pin_policy]);
    cmd.args(["--touch-policy", touch_policy]);
    if let Some(s) = serial {
        cmd.args(["--device", s]);
    }
    cmd.arg(slot);
    cmd.arg(key);

    let status = cmd
        .status()
        .context("Failed to run ykman piv keys import")?;
    if !status.success() {
        bail!("ykman piv keys import failed");
    }
    Ok(())
}

/// # Errors
///
/// If `ykman` cannot be spawned, or exits non-zero.
pub fn import_certificate(slot: &str, certificate: &Path, serial: Option<&str>) -> Result<()> {
    let mut cmd = Command::new("ykman");
    cmd.args(["piv", "certificates", "import"]);
    if let Some(s) = serial {
        cmd.args(["--device", s]);
    }
    cmd.arg(slot);
    cmd.arg(certificate);

    let status = cmd
        .status()
        .context("Failed to run ykman piv certificates import")?;
    if !status.success() {
        bail!("ykman piv certificates import failed");
    }
    Ok(())
}

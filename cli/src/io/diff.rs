use std::path::Path;
use std::process::Command;

/// # Errors
///
/// Only if `diff` cannot be spawned. Files that differ is exit 1 and files
/// that cannot be read is exit 2, both `Ok`. The diff goes to this process's
/// stdout.
pub fn unified(baseline: &Path, candidate: &Path) -> std::io::Result<std::process::ExitStatus> {
    Command::new("diff")
        .args(["-u"])
        .arg(baseline)
        .arg(candidate)
        .status()
}

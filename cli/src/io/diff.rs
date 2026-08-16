use std::path::Path;
use std::process::Command;

pub fn unified(baseline: &Path, candidate: &Path) -> std::io::Result<std::process::ExitStatus> {
    Command::new("diff")
        .args(["-u"])
        .arg(baseline)
        .arg(candidate)
        .status()
}

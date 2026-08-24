use std::process::Command;

use anyhow::Result;

use crate::io::process::run_status;

/// # Errors
///
/// Only if `bin` cannot be spawned. A hook that runs and fails is a non-zero
/// `ExitStatus`, which is what lets a caller treat a hook as advisory.
pub fn run(
    bin: &str,
    env: &[(String, String)],
    kube_context: Option<&str>,
) -> Result<std::process::ExitStatus> {
    let mut cmd = Command::new(bin);
    for (name, value) in env {
        cmd.env(name, value);
    }
    if let Some(ctx) = kube_context {
        cmd.env("KUBECONTEXT", ctx);
    }
    run_status(&mut cmd)
}

use std::process::Command;

use anyhow::{Context, Result};

use crate::io::process::run_status;

/// # Errors
///
/// Only if `helm` cannot be spawned. A failed release is a non-zero
/// `ExitStatus`, with helm's own output already on the terminal.
pub fn upgrade_install(
    release: &str,
    chart: &str,
    namespace: &str,
    values_file: &str,
    kube_context: &str,
) -> Result<std::process::ExitStatus> {
    let mut cmd = Command::new("helm");
    cmd.args([
        "upgrade",
        "--install",
        release,
        chart,
        "--namespace",
        namespace,
        "--create-namespace",
        "--values",
        values_file,
        "--kube-context",
        kube_context,
    ]);
    run_status(&mut cmd).context("running helm upgrade --install for argocd")
}

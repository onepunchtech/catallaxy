use std::process::Command;

use anyhow::Result;

use crate::io::process::run_status;

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

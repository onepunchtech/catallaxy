use std::process::Command;

use anyhow::Result;

use crate::io::process::run_output;

pub fn run(bin: &str, kube_context: &str, resource_name: &str) -> Result<std::process::Output> {
    let mut cmd = Command::new(bin);
    cmd.env("KUBECONTEXT", kube_context)
        .env("MR_NAME", resource_name);
    run_output(&mut cmd)
}

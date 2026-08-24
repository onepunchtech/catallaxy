use std::process::Command;

use anyhow::Result;
use console::style;

use crate::io::process::run_streaming;

pub struct ProviderSpec {
    pub bootstrap: Vec<String>,
    pub control_plane: Vec<String>,
    pub infrastructure: Vec<String>,
}

/// # Errors
///
/// If `clusterctl` cannot be spawned, or exits non-zero because a provider is
/// unknown or the cluster refused the install.
pub fn init(kube_context: &str, providers: &ProviderSpec) -> Result<()> {
    println!("{} Initializing Cluster API...", style(">>>").cyan());

    let mut cmd = Command::new("clusterctl");
    cmd.env("KUBECONFIG_CONTEXT", kube_context);
    cmd.args(["init"]);

    for bp in &providers.bootstrap {
        cmd.args(["--bootstrap", bp]);
    }
    for cp in &providers.control_plane {
        cmd.args(["--control-plane", cp]);
    }
    for ip in &providers.infrastructure {
        cmd.args(["--infrastructure", ip]);
    }

    run_streaming(&mut cmd)?;

    println!("{} Cluster API initialized", style(">>>").green());
    Ok(())
}

/// # Errors
///
/// Only if `clusterctl` cannot be spawned. A move that fails partway is a
/// non-zero `ExitStatus`, and Cluster API objects may exist on both sides.
pub fn move_all(from_context: &str, to_context: &str) -> std::io::Result<std::process::ExitStatus> {
    Command::new("clusterctl")
        .args([
            "move",
            "--to-kubeconfig-context",
            to_context,
            "--kubeconfig-context",
            from_context,
        ])
        .status()
}

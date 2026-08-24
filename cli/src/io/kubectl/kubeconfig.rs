use std::path::Path;

use anyhow::{Context, Result, bail};
use console::style;

use crate::io::process::run_capture;

/// # Errors
///
/// Never. A context that is not there is what the caller wanted, and kubectl's
/// exit is discarded to say so.
pub fn delete_kubeconfig_context(context_name: &str) -> Result<()> {
    let mut cmd = super::run::command();
    cmd.args(["config", "delete-context", context_name]);
    let _ = run_capture(&mut cmd);
    Ok(())
}

/// # Errors
///
/// Never; see [`delete_kubeconfig_context`].
pub fn delete_kubeconfig_cluster(cluster_name: &str) -> Result<()> {
    let mut cmd = super::run::command();
    cmd.args(["config", "delete-cluster", cluster_name]);
    let _ = run_capture(&mut cmd);
    Ok(())
}

/// # Errors
///
/// Never; see [`delete_kubeconfig_context`].
pub fn delete_kubeconfig_user(user_name: &str) -> Result<()> {
    let mut cmd = super::run::command();
    cmd.args(["config", "delete-user", user_name]);
    let _ = run_capture(&mut cmd);
    Ok(())
}

/// Fold a lab's kubeconfig into the operator's own `~/.kube/config`.
///
/// # Errors
///
/// If `HOME` is unset, if kubectl cannot flatten the two files, or if the
/// result cannot be written. The write is atomic, so a failure leaves the
/// operator's existing kubeconfig as it was rather than truncated.
pub fn merge_kubeconfig(kubeconfig_path: &Path, context_name: &str) -> Result<()> {
    println!(
        "{} Merging kubeconfig for context '{context_name}'...",
        style(">>>").cyan()
    );

    let default_kubeconfig = crate::io::fs::home_dir()?.join(".kube").join("config");

    let kubeconfig_env = format!(
        "{}:{}",
        kubeconfig_path.display(),
        default_kubeconfig.display()
    );

    let output = super::run::command()
        .env("KUBECONFIG", &kubeconfig_env)
        .args(["config", "view", "--flatten"])
        .output()?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!("Failed to merge kubeconfig: {stderr}");
    }

    crate::io::fs::write_atomic(&default_kubeconfig, &output.stdout)
        .with_context(|| format!("merging into {}", default_kubeconfig.display()))?;

    println!("{} Kubeconfig merged", style(">>>").green());

    Ok(())
}

/// # Errors
///
/// If `HOME` is unset, or the cluster's own kubeconfig file exists and cannot
/// be removed. Entries absent from the default kubeconfig are not an error.
pub fn cleanup_kubeconfig(cluster_name: &str) -> Result<()> {
    let kubeconfig_path = dirs::home_dir()
        .context("Could not find home directory")?
        .join(".kube")
        .join(format!("{cluster_name}.kubeconfig"));

    if kubeconfig_path.exists() {
        std::fs::remove_file(&kubeconfig_path)
            .with_context(|| format!("Failed to remove {}", kubeconfig_path.display()))?;
        println!(
            "{} Removed {}",
            style(">>>").green(),
            kubeconfig_path.display()
        );
    }

    delete_kubeconfig_context(&format!("{cluster_name}-admin@{cluster_name}"))?;
    delete_kubeconfig_context(cluster_name)?;

    delete_kubeconfig_cluster(cluster_name)?;
    delete_kubeconfig_user(&format!("{cluster_name}-admin"))?;

    Ok(())
}

pub fn current_context_of(kubeconfig: &Path) -> Option<String> {
    let mut cmd = super::run::command();
    cmd.env("KUBECONFIG", kubeconfig.display().to_string())
        .args(["config", "current-context"]);
    run_capture(&mut cmd).ok().map(|o| o.trim().to_string())
}

pub fn rename_context_in(kubeconfig: &Path, from: &str, to: &str) {
    let mut cmd = super::run::command();
    cmd.env("KUBECONFIG", kubeconfig.display().to_string())
        .args(["config", "rename-context", from, to]);
    let _ = run_capture(&mut cmd);
}

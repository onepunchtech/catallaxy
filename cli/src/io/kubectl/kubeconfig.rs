use std::path::Path;

use anyhow::{Context, Result, bail};
use console::style;

use crate::io::process::run_capture;

pub fn delete_kubeconfig_context(context_name: &str) -> Result<()> {
    let mut cmd = super::run::command();
    cmd.args(["config", "delete-context", context_name]);
    let _ = run_capture(&mut cmd);
    Ok(())
}

pub fn delete_kubeconfig_cluster(cluster_name: &str) -> Result<()> {
    let mut cmd = super::run::command();
    cmd.args(["config", "delete-cluster", cluster_name]);
    let _ = run_capture(&mut cmd);
    Ok(())
}

pub fn delete_kubeconfig_user(user_name: &str) -> Result<()> {
    let mut cmd = super::run::command();
    cmd.args(["config", "delete-user", user_name]);
    let _ = run_capture(&mut cmd);
    Ok(())
}

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

pub fn cleanup_kubeconfig(cluster_name: &str) -> Result<()> {
    let kubeconfig_path = dirs::home_dir()
        .context("Could not find home directory")?
        .join(".kube")
        .join(format!("{}.kubeconfig", cluster_name));

    if kubeconfig_path.exists() {
        std::fs::remove_file(&kubeconfig_path)
            .with_context(|| format!("Failed to remove {}", kubeconfig_path.display()))?;
        println!(
            "{} Removed {}",
            style(">>>").green(),
            kubeconfig_path.display()
        );
    }

    delete_kubeconfig_context(&format!("{}-admin@{}", cluster_name, cluster_name))?;
    delete_kubeconfig_context(cluster_name)?;

    delete_kubeconfig_cluster(cluster_name)?;
    delete_kubeconfig_user(&format!("{}-admin", cluster_name))?;

    Ok(())
}

pub fn context_in_kubeconfig(context: &str) -> bool {
    super::run::command()
        .args(["config", "get-contexts", "-o", "name", context])
        .output()
        .ok()
        .map(|o| o.status.success())
        .unwrap_or(false)
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

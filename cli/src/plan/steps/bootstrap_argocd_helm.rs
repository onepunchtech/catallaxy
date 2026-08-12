use std::path::Path;
use std::process::Command;

use anyhow::{Context, Result, bail};
use console::style;

use crate::plan::StepContext;

pub fn run(
    sctx: &StepContext<'_>,
    target: &str,
    kube_context: Option<&str>,
    values_path: &str,
    chart_ref: &str,
    release_name: &str,
    namespace: Option<&str>,
    _wait_timeout_seconds: Option<u64>,
) -> Result<()> {
    let kube_context = kube_context.ok_or_else(|| {
        anyhow::anyhow!(
            "bootstrap-argocd-helm: missing kubeContext for target '{target}'. \
             The planner must populate `kubeContext` (see `runtimeCtxOf` in \
             `lib/eval/deployment-plan.nix`)."
        )
    })?;
    let namespace = namespace.unwrap_or("argocd");
    let full_values = format!("{}/{values_path}", sctx.lab_package);
    if !Path::new(&full_values).exists() {
        bail!(
            "argocd helm values not found at {full_values}. \
             Rebuild the lab package; ensure lab.cd.strategy = argocd, \
             lab.cd.bootstrap = helm, and lib/render/argocd.nix ran."
        );
    }
    if sctx.dry_run {
        println!(
            "{} Would helm upgrade --install {release_name} {chart_ref} \
             --namespace {namespace} --create-namespace --values {full_values} \
             --kube-context {kube_context}",
            style(">>>").yellow()
        );
        return Ok(());
    }
    println!(
        "{} Installing argocd on '{kube_context}' via helm (chart={chart_ref}, release={release_name})...",
        style(">>>").cyan(),
    );
    let status = Command::new("helm")
        .args([
            "upgrade",
            "--install",
            release_name,
            chart_ref,
            "--namespace",
            namespace,
            "--create-namespace",
            "--values",
            &full_values,
            "--kube-context",
            kube_context,
        ])
        .status()
        .context("running helm upgrade --install for argocd")?;
    if !status.success() {
        bail!("helm install of argocd failed");
    }
    println!(
        "{} argocd installed on '{kube_context}' via helm",
        style(">>>").green()
    );
    Ok(())
}

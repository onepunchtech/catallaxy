use std::path::Path;
use std::process::Command;

use anyhow::{Context, Result, bail};
use console::style;

use crate::plan::StepContext;

pub struct ArgocdHelm<'a> {
    pub target: &'a str,
    pub kube_context: Option<&'a str>,
    pub values_path: &'a str,
    pub chart_ref: &'a str,
    pub release_name: &'a str,
    pub namespace: Option<&'a str>,
}

pub fn run(sctx: &StepContext<'_>, install: ArgocdHelm<'_>) -> Result<()> {
    let ArgocdHelm {
        target,
        kube_context,
        values_path,
        chart_ref,
        release_name,
        namespace,
    } = install;
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
    let mut cmd = Command::new("helm");
    cmd.args([
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
    ]);
    let status = crate::io::process::run_status(&mut cmd)
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

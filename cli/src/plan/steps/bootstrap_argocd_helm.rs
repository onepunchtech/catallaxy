use std::path::Path;

use anyhow::{Result, bail};
use console::style;

use crate::domain::plan::BootstrapArgocdHelmParams;
use crate::plan::StepContext;

pub fn run(sctx: &StepContext<'_>, p: &BootstrapArgocdHelmParams) -> Result<()> {
    let BootstrapArgocdHelmParams {
        target,
        values_path,
        chart_ref,
        release_name,
        kube_context,
        namespace,
        wait_timeout_seconds: _,
    } = p;
    let kube_context = kube_context.as_deref();
    let namespace = namespace.as_deref();

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
    let status = crate::io::helm::upgrade_install(
        release_name,
        chart_ref,
        namespace,
        &full_values,
        kube_context,
    )?;
    if !status.success() {
        bail!("helm install of argocd failed");
    }
    println!(
        "{} argocd installed on '{kube_context}' via helm",
        style(">>>").green()
    );
    Ok(())
}

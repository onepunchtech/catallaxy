use std::process::Command;

use anyhow::{Context, Result, bail};
use console::style;

use crate::domain::plan::VerifyArgocdReachableParams;
use crate::plan::StepContext;

pub fn run(sctx: &StepContext<'_>, p: &VerifyArgocdReachableParams) -> Result<()> {
    let VerifyArgocdReachableParams {
        target,
        kube_context,
        namespace,
    } = p;
    let kube_context = kube_context.as_deref();
    let namespace = namespace.as_deref();

    let kube_context = kube_context.ok_or_else(|| {
        anyhow::anyhow!(
            "verify-argocd-reachable: missing kubeContext for target '{target}'. \
             The planner must populate `kubeContext` (see `runtimeCtxOf` in \
             `lib/eval/deployment-plan.nix`)."
        )
    })?;
    let namespace = namespace.unwrap_or("argocd");
    if sctx.dry_run {
        println!(
            "{} Would kubectl -n {namespace} --context {kube_context} get deploy argocd-server",
            style(">>>").yellow()
        );
        return Ok(());
    }
    let status = Command::new("kubectl")
        .args([
            "--context",
            kube_context,
            "-n",
            namespace,
            "get",
            "deploy",
            "argocd-server",
        ])
        .status()
        .context("running kubectl get deploy argocd-server")?;
    if !status.success() {
        bail!(
            "argocd-server Deployment not found in namespace '{namespace}' on '{kube_context}'. \
             lab.cd.bootstrap = \"none\" requires argocd to be pre-installed."
        );
    }
    println!(
        "{} argocd is reachable on '{kube_context}' (namespace {namespace})",
        style(">>>").green()
    );
    Ok(())
}

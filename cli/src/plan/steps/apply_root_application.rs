use std::path::Path;

use anyhow::{Context, Result, bail};
use console::style;

use crate::domain::plan::ApplyRootApplicationParams;
use crate::io;
use crate::plan::StepContext;

pub fn run(sctx: &StepContext<'_>, p: &ApplyRootApplicationParams) -> Result<()> {
    let ApplyRootApplicationParams {
        target,
        namespace,
        manifest_path,
        kube_context,
    } = p;
    let _namespace = namespace.as_deref();
    let manifest_path = manifest_path.as_deref();
    let kube_context = kube_context.as_deref();

    let kube_context = kube_context.ok_or_else(|| {
        crate::plan::steps::missing_kube_context("apply-root-application", target)
    })?;
    let manifest_path = manifest_path.unwrap_or("");
    if manifest_path.is_empty() {
        bail!("apply-root-application step missing manifestPath");
    }
    let full_path = format!("{}/{manifest_path}", sctx.lab_package);
    if !Path::new(&full_path).exists() {
        bail!(
            "root Application manifest not found at {full_path}. \
             Rebuild the lab package; ensure lab.cd.strategy = argocd \
             and lib/render/argocd.nix ran."
        );
    }
    if sctx.dry_run {
        println!(
            "{} Would kubectl apply -f {full_path} --context={kube_context}",
            style(">>>").yellow()
        );
        return Ok(());
    }
    println!(
        "{} Applying argocd root Application to '{kube_context}' (starts gitops sync)...",
        style(">>>").cyan(),
    );
    let status = io::kubectl::status(kube_context, &["apply", "-f", &full_path])
        .context("running kubectl apply for root Application")?;
    if !status.success() {
        bail!("kubectl apply of root Application failed");
    }
    let bundles_root = Path::new(&full_path)
        .parent()
        .map(|p| p.join("bundles"))
        .unwrap_or_default();
    crate::io::ssa::relinquish_field_manager(
        kube_context,
        &bundles_root,
        "catallaxy-bootstrap",
        sctx.dry_run,
    )?;

    println!(
        "{} argocd now owns lab reconciliation via git",
        style(">>>").green()
    );
    Ok(())
}

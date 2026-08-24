use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use console::style;

use crate::domain::plan::BootstrapForgejoReposParams;
use crate::io;
use crate::plan::StepContext;

const DEFAULT_NAMESPACE: &str = "forgejo";
const DEFAULT_SELECTOR: &str = "app.kubernetes.io/component=forgejo-bootstrap";
const WAIT_TIMEOUT_SECS: u64 = 600;

pub async fn run(sctx: &StepContext<'_>, p: &BootstrapForgejoReposParams) -> Result<()> {
    let BootstrapForgejoReposParams {
        target,
        namespace,
        job_label_selector: selector,
        kube_context,
    } = p;
    let namespace = namespace.as_deref();
    let selector = selector.as_deref();
    let kube_context = kube_context.as_deref();

    let namespace = namespace.unwrap_or(DEFAULT_NAMESPACE);
    let selector = selector.unwrap_or(DEFAULT_SELECTOR);
    let kube_context = kube_context.ok_or_else(|| {
        crate::plan::steps::missing_kube_context("bootstrap-forgejo-repos", target)
    })?;

    if sctx.dry_run {
        println!(
            "{} Would wait for job -l {selector} in ns {namespace} on '{kube_context}'",
            style(">>>").yellow()
        );
        return Ok(());
    }

    println!(
        "{} Waiting for forgejo-bootstrap Job on '{kube_context}'...",
        style(">>>").cyan(),
    );

    let poll_start = Instant::now();
    let poll_max = Duration::from_secs(60);
    loop {
        let out = io::kubectl::output(
            kube_context,
            &[
                "-n",
                namespace,
                "get",
                "job",
                "-l",
                selector,
                "--no-headers",
            ],
        );
        if out.as_ref().map(|o| !o.stdout.is_empty()).unwrap_or(false) {
            break;
        }
        if poll_start.elapsed() > poll_max {
            bail!(
                "Timed out waiting for a matching Job to appear \
                 (-l {selector}, ns {namespace}, ctx {kube_context}). \
                 Confirm the forgejo bootstrap module is enabled and \
                 the forgejo phase deploy-manifests step ran."
            );
        }
        tokio::time::sleep(Duration::from_secs(5)).await;
    }

    let status = io::kubectl::status(
        kube_context,
        &[
            "-n",
            namespace,
            "wait",
            "--for=condition=Complete",
            "job",
            "-l",
            selector,
            &format!("--timeout={WAIT_TIMEOUT_SECS}s"),
        ],
    )
    .context("running kubectl wait for forgejo-bootstrap Job")?;
    if !status.success() {
        bail!(
            "forgejo-bootstrap Job did not reach Complete within \
             {WAIT_TIMEOUT_SECS}s. Inspect: \
             kubectl -n {namespace} logs -l {selector} --tail=200"
        );
    }
    println!("{} forgejo-bootstrap complete", style(">>>").green());
    Ok(())
}

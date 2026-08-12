use std::process::Command;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use console::style;

use crate::plan::StepContext;

const DEFAULT_NAMESPACE: &str = "forgejo";
const DEFAULT_SELECTOR: &str = "app.kubernetes.io/component=forgejo-bootstrap";
const WAIT_TIMEOUT_SECS: u64 = 600;

pub async fn run(
    sctx: &StepContext<'_>,
    target: &str,
    namespace: Option<&str>,
    selector: Option<&str>,
    kube_context: Option<&str>,
) -> Result<()> {
    let namespace = namespace.unwrap_or(DEFAULT_NAMESPACE);
    let selector = selector.unwrap_or(DEFAULT_SELECTOR);
    let kube_context = kube_context.ok_or_else(|| {
        anyhow::anyhow!(
            "bootstrap-forgejo-repos: missing kubeContext for target '{target}'. \
             The planner must populate `kubeContext` (see `runtimeCtxOf` in \
             `lib/eval/deployment-plan.nix`)."
        )
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
        let out = Command::new("kubectl")
            .args([
                "--context",
                kube_context,
                "-n",
                namespace,
                "get",
                "job",
                "-l",
                selector,
                "--no-headers",
            ])
            .output();
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

    let status = Command::new("kubectl")
        .args([
            "--context",
            kube_context,
            "-n",
            namespace,
            "wait",
            "--for=condition=Complete",
            "job",
            "-l",
            selector,
            &format!("--timeout={WAIT_TIMEOUT_SECS}s"),
        ])
        .status()
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

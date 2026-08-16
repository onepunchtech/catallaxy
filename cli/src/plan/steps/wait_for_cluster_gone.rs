use std::time::Duration;

use anyhow::Result;
use console::style;

use crate::domain::plan::WaitForClusterGoneParams;
use crate::domain::{ResourceRef, StepFailure};
use crate::plan::StepContext;

const STEP: &str = "wait-for-cluster-gone";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Gone,
    StillPresent,
    CannotTell,
}

pub fn run(sctx: &StepContext<'_>, p: &WaitForClusterGoneParams) -> Result<()> {
    let WaitForClusterGoneParams {
        target,
        kube_context,
        resource_kind: kind,
        resource_name,
        wait_timeout_seconds: timeout_secs,
    } = p;
    let timeout_secs = timeout_secs.unwrap_or(600);
    let target = target.as_deref();
    let kube_context = kube_context.as_deref();
    let kind = kind.as_deref();
    let resource_name = resource_name.as_deref();

    let target = target.unwrap_or("unknown");
    let kube_ctx = kube_context
        .map(String::from)
        .unwrap_or_else(|| target.to_string());
    let kind = kind.unwrap_or("");
    let resource_name = resource_name.unwrap_or(target);

    let cluster_confirmed_gone = if kind.is_empty() {
        println!(
            "{} wait-for-cluster-gone for '{target}' has no kind, skipping",
            style("Warning:").yellow(),
        );
        sctx.failures.borrow_mut().push(StepFailure::new(
            STEP,
            format!("'{target}' has no resource kind, so nothing could be confirmed"),
        ));
        false
    } else if prior_delete_failed(sctx, &ResourceRef::new(kind, resource_name)) {
        println!(
            "{} {}/{} delete-managed-resource step failed earlier, skipping wait (nothing will remove the CR). Recover as instructed above and re-run destroy.",
            style("ERROR").red(),
            kind,
            resource_name,
        );
        sctx.failures.borrow_mut().push(StepFailure::on_resource(
            STEP,
            kind,
            resource_name,
            "the delete step failed earlier, so nothing was going to remove the CR",
        ));
        false
    } else {
        match poll_until_gone(&kube_ctx, kind, resource_name, timeout_secs) {
            Outcome::Gone => true,
            Outcome::StillPresent => {
                println!(
                    "{} {}/{} still present on '{}' after timeout",
                    style("Warning:").yellow(),
                    kind,
                    resource_name,
                    kube_ctx,
                );
                sctx.failures.borrow_mut().push(StepFailure::on_resource(
                    STEP,
                    kind,
                    resource_name,
                    format!("still present on '{kube_ctx}' after {timeout_secs}s"),
                ));
                false
            }
            Outcome::CannotTell => {
                println!(
                    "{} '{}' never became readable, so whether {}/{} was destroyed is unknown. \
                     The cloud resource may still exist.",
                    style("ERROR").red(),
                    kube_ctx,
                    kind,
                    resource_name,
                );
                sctx.failures.borrow_mut().push(StepFailure::on_resource(
                    STEP,
                    kind,
                    resource_name,
                    format!(
                        "'{kube_ctx}' was unreachable for {timeout_secs}s, so deletion was never confirmed"
                    ),
                ));
                false
            }
        }
    };

    if cluster_confirmed_gone && let Err(e) = crate::io::kubectl::cleanup_kubeconfig(target) {
        println!(
            "{} Kubeconfig cleanup for '{target}' failed: {e}",
            style("Warning:").yellow(),
        );
    }
    Ok(())
}

fn prior_delete_failed(sctx: &StepContext<'_>, resource: &ResourceRef) -> bool {
    sctx.failures
        .borrow()
        .iter()
        .any(|f| f.step == "delete-managed-resource" && f.concerns(resource))
}

pub fn classify(status_ok: bool, stdout: &[u8]) -> Outcome {
    match (status_ok, stdout.is_empty()) {
        (true, true) => Outcome::Gone,
        (true, false) => Outcome::StillPresent,
        (false, _) => Outcome::CannotTell,
    }
}

fn poll_until_gone(kube_ctx: &str, kind: &str, resource_name: &str, timeout_secs: u64) -> Outcome {
    let mut last = Outcome::CannotTell;
    let gone = crate::io::poll::poll_while_time_remains(
        Duration::from_secs(timeout_secs),
        Duration::from_secs(20),
        || {
            let out = crate::io::kubectl::output(
                kube_ctx,
                &[
                    "get",
                    kind,
                    resource_name,
                    "--ignore-not-found",
                    "-o",
                    "name",
                ],
            );
            match out {
                Ok(o) => {
                    let stderr = String::from_utf8_lossy(&o.stderr);
                    last = classify(o.status.success(), &o.stdout);
                    match last {
                        Outcome::Gone => {
                            println!(
                                "{} {}/{} gone from '{}'; deletion confirmed",
                                style(">>>").green(),
                                kind,
                                resource_name,
                                kube_ctx,
                            );
                            return Some(Outcome::Gone);
                        }
                        Outcome::StillPresent => println!(
                            "{} {}/{} still present on '{}'; waiting for Crossplane to finish...",
                            style(">>>").yellow(),
                            kind,
                            resource_name,
                            kube_ctx,
                        ),
                        Outcome::CannotTell => println!(
                            "{} cannot read {}/{} on '{}' ({}); retrying...",
                            style(">>>").yellow(),
                            kind,
                            resource_name,
                            kube_ctx,
                            stderr.trim().lines().next().unwrap_or("no stderr"),
                        ),
                    }
                }
                Err(e) => {
                    last = Outcome::CannotTell;
                    println!(
                        "{} could not run kubectl for {}/{} on '{}': {e}; retrying...",
                        style(">>>").yellow(),
                        kind,
                        resource_name,
                        kube_ctx,
                    );
                }
            }
            None
        },
    );
    gone.unwrap_or(last)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_successful_get_is_the_only_proof_of_deletion() {
        assert_eq!(classify(true, b""), Outcome::Gone);
    }

    #[test]
    fn a_named_resource_is_still_present() {
        assert_eq!(
            classify(true, b"cluster.x.io/workload\n"),
            Outcome::StillPresent
        );
    }

    #[test]
    fn a_failed_get_is_never_evidence_of_deletion() {
        assert_eq!(classify(false, b""), Outcome::CannotTell);
        assert_eq!(
            classify(false, b"cluster.x.io/workload\n"),
            Outcome::CannotTell
        );
    }
}

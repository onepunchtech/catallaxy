use std::process::Command;
use std::time::{Duration, Instant};

use anyhow::Result;
use console::style;

use crate::plan::StepContext;

const UNREACHABLE_SIGNALS: &[&str] = &[
    "Unable to connect to the server",
    "no such host",
    "connection refused",
    "context deadline exceeded",
    "does not exist",
    "i/o timeout",
    "TLS handshake",
    "doesn't have a resource type",
    "the server could not find the requested resource",
];

pub fn run(
    sctx: &StepContext<'_>,
    target: Option<&str>,
    kube_context: Option<&str>,
    kind: Option<&str>,
    resource_name: Option<&str>,
    timeout_secs: u64,
) -> Result<()> {
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
        sctx.failures
            .borrow_mut()
            .push(format!("wait-for-cluster-gone {target}"));
        false
    } else if prior_delete_failed(sctx, kind, resource_name) {
        println!(
            "{} {}/{} delete-managed-resource step failed earlier, skipping wait (nothing will remove the CR). Recover as instructed above and re-run destroy.",
            style("ERROR").red(),
            kind,
            resource_name,
        );
        sctx.failures.borrow_mut().push(format!(
            "wait-for-cluster-gone {kind}/{resource_name}: prior delete step failed"
        ));
        false
    } else if !poll_until_gone(&kube_ctx, kind, resource_name, timeout_secs) {
        println!(
            "{} {}/{} still present on '{}' after timeout",
            style("Warning:").yellow(),
            kind,
            resource_name,
            kube_ctx,
        );
        sctx.failures
            .borrow_mut()
            .push(format!("wait-for-cluster-gone {kind}/{resource_name}"));
        false
    } else {
        true
    };

    if cluster_confirmed_gone && let Err(e) = crate::io::kubectl::cleanup_kubeconfig(target) {
        println!(
            "{} Kubeconfig cleanup for '{target}' failed: {e}",
            style("Warning:").yellow(),
        );
    }
    Ok(())
}

fn prior_delete_failed(sctx: &StepContext<'_>, kind: &str, resource_name: &str) -> bool {
    let needle = format!("delete-managed-resource {kind}/{resource_name}");
    sctx.failures.borrow().iter().any(|f| f.contains(&needle))
}

fn poll_until_gone(kube_ctx: &str, kind: &str, resource_name: &str, timeout_secs: u64) -> bool {
    let deadline = Instant::now() + Duration::from_secs(timeout_secs);
    while Instant::now() < deadline {
        let out = Command::new("kubectl")
            .args([
                "--context",
                kube_ctx,
                "get",
                kind,
                resource_name,
                "--ignore-not-found",
                "-o",
                "name",
            ])
            .output();
        match out {
            Ok(o) if o.status.success() => {
                if o.stdout.is_empty() {
                    println!(
                        "{} {}/{} gone from '{}'; cluster confirmed destroyed",
                        style(">>>").green(),
                        kind,
                        resource_name,
                        kube_ctx,
                    );
                    return true;
                }
                println!(
                    "{} {}/{} still present on '{}'; waiting for Crossplane to finish...",
                    style(">>>").yellow(),
                    kind,
                    resource_name,
                    kube_ctx,
                );
            }
            Ok(o) => {
                let stderr = String::from_utf8_lossy(&o.stderr);
                if UNREACHABLE_SIGNALS.iter().any(|p| stderr.contains(p)) {
                    println!(
                        "{} '{}' kube-api no longer reachable; assuming Crossplane finished destroying {}/{}",
                        style(">>>").green(),
                        kube_ctx,
                        kind,
                        resource_name,
                    );
                    return true;
                }
                println!(
                    "{} kubectl get {}/{} failed on '{}'; retrying...",
                    style(">>>").yellow(),
                    kind,
                    resource_name,
                    kube_ctx,
                );
            }
            Err(_) => {
                println!(
                    "{} kubectl get {}/{} failed on '{}'; retrying...",
                    style(">>>").yellow(),
                    kind,
                    resource_name,
                    kube_ctx,
                );
            }
        }
        std::thread::sleep(Duration::from_secs(20));
    }
    false
}

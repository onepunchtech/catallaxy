use std::process::Command;
use std::time::{Duration, Instant};

use anyhow::Result;
use console::style;
use serde_json::Value;

use crate::domain::plan::DeleteManagedResourceParams;
use crate::io;
use crate::plan::StepContext;

pub fn run(sctx: &StepContext<'_>, p: &DeleteManagedResourceParams) -> Result<()> {
    let DeleteManagedResourceParams {
        target,
        resource_kind: kind,
        resource_name,
        wait,
        wait_timeout_seconds: timeout_secs,
        kube_context,
        external_name_discovery_bin: _,
    } = p;
    let wait = wait.unwrap_or(true);
    let timeout_secs = timeout_secs.unwrap_or(1200);
    let kube_context = kube_context.as_deref();

    let kube_ctx = kube_context
        .map(String::from)
        .unwrap_or_else(|| target.to_string());

    if kind.is_empty() {
        sctx.failures
            .borrow_mut()
            .push("delete-managed-resource: missing kind".into());
        return Ok(());
    }
    if !io::kubectl::api_reachable(&kube_ctx) {
        println!(
            "{} '{}' not reachable; can't delete {}/{}",
            style("Warning:").yellow(),
            kube_ctx,
            kind,
            resource_name,
        );
        sctx.failures.borrow_mut().push(format!(
            "delete-managed-resource {kind}/{resource_name} on {kube_ctx}"
        ));
        return Ok(());
    }

    match fetch_cr(&kube_ctx, kind, resource_name) {
        None => report_missing_cr(sctx, &kube_ctx, kind, resource_name),
        Some(cr) => {
            if !preflight_safe_to_delete(&cr, &kube_ctx, kind, resource_name) {
                sctx.failures.borrow_mut().push(format!(
                    "delete-managed-resource {kind}/{resource_name}: preflight failed"
                ));
                return Ok(());
            }
            if !issue_delete(sctx, &kube_ctx, kind, resource_name, wait) {
                return Ok(());
            }
            if wait && !poll_until_gone(&kube_ctx, kind, resource_name, timeout_secs) {
                sctx.failures.borrow_mut().push(format!(
                    "delete-managed-resource {kind}/{resource_name} on {kube_ctx}"
                ));
            }
        }
    }
    Ok(())
}

fn fetch_cr(kube_ctx: &str, kind: &str, resource_name: &str) -> Option<Value> {
    let out = Command::new("kubectl")
        .args([
            "--context",
            kube_ctx,
            "get",
            &format!("{kind}/{resource_name}"),
            "-o",
            "json",
        ])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    serde_json::from_slice(&out.stdout).ok()
}

fn report_missing_cr(sctx: &StepContext<'_>, kube_ctx: &str, kind: &str, resource_name: &str) {
    let existing = list_all_of_kind(kube_ctx, kind);
    if existing.is_empty() {
        println!(
            "{} {}/{} not found on '{}'; nothing to delete",
            style(">>>").green(),
            kind,
            resource_name,
            kube_ctx,
        );
        return;
    }
    println!(
        "{} {}/{} not found on '{}', but {} other {} CR(s) exist:",
        style("Warning:").yellow(),
        kind,
        resource_name,
        kube_ctx,
        existing.len(),
        kind,
    );
    for (n, ext) in &existing {
        let ext_disp = if ext.is_empty() {
            "<missing>"
        } else {
            ext.as_str()
        };
        println!("    - {n}  (external-name={ext_disp})");
    }
    println!(
        "{} Likely cause: cluster attr names in Nix don't match the CRs\n\
         {} that were created before the rename. Recover using your cloud\n\
         {} provider's own console/CLI to delete the orphaned resources,\n\
         {} then force-remove the stale CRs (they can no longer fire a\n\
         {} cascade destroy since the cloud resource is gone):\n\
         {}   kubectl --context {kube_ctx} patch {kind}/<name> --type merge \\\n\
         {}     -p '{{\"metadata\":{{\"finalizers\":[]}}}}'\n\
         {}   kubectl --context {kube_ctx} delete {kind}/<name> --ignore-not-found",
        style(">>>").yellow(),
        style(">>>").yellow(),
        style(">>>").yellow(),
        style(">>>").yellow(),
        style(">>>").yellow(),
        style(">>>").dim(),
        style(">>>").dim(),
        style(">>>").dim(),
    );
    sctx.failures.borrow_mut().push(format!(
        "delete-managed-resource {kind}/{resource_name}: not found; {} orphaned CR(s) present",
        existing.len(),
    ));
}

fn list_all_of_kind(kube_ctx: &str, kind: &str) -> Vec<(String, String)> {
    let out = Command::new("kubectl")
        .args([
            "--context", kube_ctx,
            "get", kind, "-A",
            "-o", r#"jsonpath={range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.crossplane\.io/external-name}{"\n"}{end}"#,
        ])
        .output()
        .ok();
    let Some(out) = out.filter(|o| o.status.success()) else {
        return Vec::new();
    };
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| {
            let mut parts = l.splitn(2, '\t');
            let n = parts.next()?.trim().to_string();
            let ext = parts.next().unwrap_or("").trim().to_string();
            if n.is_empty() { None } else { Some((n, ext)) }
        })
        .collect()
}

fn preflight_safe_to_delete(cr: &Value, kube_ctx: &str, kind: &str, resource_name: &str) -> bool {
    let external_name = cr
        .pointer("/metadata/annotations/crossplane.io~1external-name")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty());
    let has_xp_finalizer = cr
        .pointer("/metadata/finalizers")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter().any(|f| {
                f.as_str()
                    .map(|s| s.contains("crossplane.io"))
                    .unwrap_or(false)
            })
        })
        .unwrap_or(false);

    if let Some(name) = external_name
        && has_xp_finalizer
    {
        println!(
            "{} Preflight OK: external-name='{name}', finalizer attached",
            style(">>>").green(),
        );
        return true;
    }

    let ext_str = external_name.unwrap_or("<missing>");
    println!(
        "{} delete-managed-resource {kind}/{resource_name}: unsafe to delete: external-name='{ext_str}', crossplane-finalizer={has_xp_finalizer}. \n  \
         A `kubectl delete` here would remove the CR from k8s WITHOUT firing a cloud-side destroy, leaving the underlying resource orphaned. \n  \
         Recover with your provider's tooling:\n    \
         1. Use your cloud provider's CLI/console to look up the resource UUID that corresponds to {kind}/{resource_name}.\n    \
         2. kubectl --context {kube_ctx} annotate {kind}/{resource_name} crossplane.io/external-name=<UUID> --overwrite\n    \
         3. kubectl --context {kube_ctx} wait --for=condition=Ready {kind}/{resource_name} --timeout=120s\n    \
         4. Re-run `cata lab destroy`.\n  \
         If the cloud resource is already gone, strip the finalizer:\n    \
         kubectl --context {kube_ctx} patch {kind}/{resource_name} --type merge -p '{{\"metadata\":{{\"finalizers\":[]}}}}'",
        style("ERROR").red(),
    );
    false
}

fn issue_delete(
    sctx: &StepContext<'_>,
    kube_ctx: &str,
    kind: &str,
    resource_name: &str,
    wait: bool,
) -> bool {
    println!(
        "{} kubectl --context {kube_ctx} delete {kind}/{resource_name}",
        style(">>>").cyan(),
    );
    let mut args = vec![
        "--context".to_string(),
        kube_ctx.to_string(),
        "delete".to_string(),
        format!("{kind}/{resource_name}"),
        "--ignore-not-found".to_string(),
    ];
    if !wait {
        args.push("--wait=false".to_string());
    }
    match Command::new("kubectl").args(&args).status() {
        Ok(s) if s.success() => {
            println!("{} delete request accepted", style(">>>").green());
            true
        }
        Ok(s) => {
            println!(
                "{} kubectl delete exited {}; continuing",
                style("Warning:").yellow(),
                s.code().unwrap_or(-1),
            );
            sctx.failures.borrow_mut().push(format!(
                "delete-managed-resource {kind}/{resource_name} on {kube_ctx}"
            ));
            false
        }
        Err(e) => {
            println!("{} kubectl invocation failed: {e}", style("ERROR").red());
            sctx.failures.borrow_mut().push(format!(
                "delete-managed-resource {kind}/{resource_name} on {kube_ctx}"
            ));
            false
        }
    }
}

fn poll_until_gone(kube_ctx: &str, kind: &str, resource_name: &str, timeout_secs: u64) -> bool {
    let deadline = Instant::now() + Duration::from_secs(timeout_secs);
    while Instant::now() < deadline {
        let out = Command::new("kubectl")
            .args([
                "--context",
                kube_ctx,
                "get",
                &format!("{kind}/{resource_name}"),
                "--no-headers",
                "--ignore-not-found",
            ])
            .output();
        if let Ok(o) = out
            && String::from_utf8_lossy(&o.stdout).trim().is_empty()
        {
            println!(
                "{} {}/{} deleted",
                style(">>>").green(),
                kind,
                resource_name
            );
            return true;
        }
        println!(
            "{} still waiting on Crossplane to destroy {}/{}...",
            style(">>>").yellow(),
            kind,
            resource_name,
        );
        std::thread::sleep(Duration::from_secs(20));
    }
    println!(
        "{} Timed out waiting for {}/{} to be deleted",
        style("Warning:").yellow(),
        kind,
        resource_name,
    );
    false
}

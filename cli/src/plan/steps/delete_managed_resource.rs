use std::time::Duration;

use anyhow::Result;
use console::style;
use serde_json::Value;

use crate::domain::StepFailure;
use crate::domain::crossplane::ManagedState;
use crate::domain::plan::DeleteManagedResourceParams;
use crate::io;
use crate::plan::StepContext;

const STEP: &str = "delete-managed-resource";

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
            .push(StepFailure::new(STEP, "missing kind"));
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
        sctx.failures.borrow_mut().push(StepFailure::on_resource(
            STEP,
            kind,
            resource_name,
            format!("'{kube_ctx}' not reachable, so the CR was never deleted"),
        ));
        return Ok(());
    }

    match fetch_cr(&kube_ctx, kind, resource_name) {
        None => report_missing_cr(sctx, &kube_ctx, kind, resource_name),
        Some(cr) => {
            if !preflight_safe_to_delete(&cr, &kube_ctx, kind, resource_name) {
                sctx.failures.borrow_mut().push(StepFailure::on_resource(
                    STEP,
                    kind,
                    resource_name,
                    "preflight refused the delete",
                ));
                return Ok(());
            }
            if !issue_delete(sctx, &kube_ctx, kind, resource_name, wait) {
                return Ok(());
            }
            if wait && !poll_until_gone(&kube_ctx, kind, resource_name, timeout_secs) {
                sctx.failures.borrow_mut().push(StepFailure::on_resource(
                    STEP,
                    kind,
                    resource_name,
                    format!("still present on '{kube_ctx}' after {timeout_secs}s"),
                ));
            }
        }
    }
    Ok(())
}

fn fetch_cr(kube_ctx: &str, kind: &str, resource_name: &str) -> Option<Value> {
    io::kubectl::resource_json(kube_ctx, &format!("{kind}/{resource_name}"))
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
    sctx.failures.borrow_mut().push(StepFailure::on_resource(
        STEP,
        kind,
        resource_name,
        format!("not found; {} orphaned CR(s) present", existing.len()),
    ));
}

fn list_all_of_kind(kube_ctx: &str, kind: &str) -> Vec<(String, String)> {
    let out = io::kubectl::output(
        kube_ctx,
        &[
            "get", kind, "-A",
            "-o", r#"jsonpath={range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.crossplane\.io/external-name}{"\n"}{end}"#,
        ],
    )
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

pub fn describe_unsafe_delete(
    state: &ManagedState,
    kube_ctx: &str,
    kind: &str,
    resource_name: &str,
) -> String {
    format!(
        "delete-managed-resource {kind}/{resource_name}: unsafe to delete: external-name='{}', crossplane-finalizer={}. \n  \
         A `kubectl delete` here would remove the CR from k8s WITHOUT firing a cloud-side destroy, leaving the underlying resource orphaned. \n  \
         Recover with your provider's tooling:\n    \
         1. Use your cloud provider's CLI/console to look up the resource UUID that corresponds to {kind}/{resource_name}.\n    \
         2. kubectl --context {kube_ctx} annotate {kind}/{resource_name} crossplane.io/external-name=<UUID> --overwrite\n    \
         3. kubectl --context {kube_ctx} wait --for=condition=Ready {kind}/{resource_name} --timeout=120s\n    \
         4. Re-run `cata lab destroy`.\n  \
         If the cloud resource is already gone, strip the finalizer:\n    \
         kubectl --context {kube_ctx} patch {kind}/{resource_name} --type merge -p '{{\"metadata\":{{\"finalizers\":[]}}}}'",
        state.external_name_or_missing(),
        state.has_finalizer,
    )
}

fn preflight_safe_to_delete(cr: &Value, kube_ctx: &str, kind: &str, resource_name: &str) -> bool {
    let state = ManagedState::of(cr);

    if state.is_deletable() {
        println!(
            "{} Preflight OK: external-name='{}', finalizer attached",
            style(">>>").green(),
            state.external_name_or_missing(),
        );
        return true;
    }

    println!(
        "{} {}",
        style("ERROR").red(),
        describe_unsafe_delete(&state, kube_ctx, kind, resource_name),
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
    let target = format!("{kind}/{resource_name}");
    let mut args = vec!["delete", target.as_str(), "--ignore-not-found"];
    if !wait {
        args.push("--wait=false");
    }
    match io::kubectl::status(kube_ctx, &args) {
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
            sctx.failures.borrow_mut().push(StepFailure::on_resource(
                STEP,
                kind,
                resource_name,
                format!(
                    "kubectl delete on '{kube_ctx}' exited {}",
                    s.code().unwrap_or(-1)
                ),
            ));
            false
        }
        Err(e) => {
            println!("{} kubectl invocation failed: {e}", style("ERROR").red());
            sctx.failures.borrow_mut().push(StepFailure::on_resource(
                STEP,
                kind,
                resource_name,
                format!("kubectl could not be run against '{kube_ctx}': {e}"),
            ));
            false
        }
    }
}

fn poll_until_gone(kube_ctx: &str, kind: &str, resource_name: &str, timeout_secs: u64) -> bool {
    let deleted = crate::io::poll::poll_while_time_remains(
        Duration::from_secs(timeout_secs),
        Duration::from_secs(20),
        || {
            let out = io::kubectl::output(
                kube_ctx,
                &[
                    "get",
                    &format!("{kind}/{resource_name}"),
                    "--no-headers",
                    "--ignore-not-found",
                ],
            );
            if let Ok(o) = out
                && String::from_utf8_lossy(&o.stdout).trim().is_empty()
            {
                println!(
                    "{} {}/{} deleted",
                    style(">>>").green(),
                    kind,
                    resource_name
                );
                return Some(());
            }
            println!(
                "{} still waiting on Crossplane to destroy {}/{}...",
                style(">>>").yellow(),
                kind,
                resource_name,
            );
            None
        },
    );
    if deleted.is_some() {
        return true;
    }
    println!(
        "{} Timed out waiting for {}/{} to be deleted",
        style("Warning:").yellow(),
        kind,
        resource_name,
    );
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_deletable_resource_produces_no_runbook() {
        let cr = json!({
            "metadata": {
                "annotations": { "crossplane.io/external-name": "uuid-1" },
                "finalizers": ["finalizer.managedresource.crossplane.io"],
            }
        });

        assert!(ManagedState::of(&cr).is_deletable());
    }

    #[test]
    fn the_runbook_names_the_resource_and_what_is_missing() {
        let state = ManagedState::of(&json!({
            "metadata": { "finalizers": ["finalizer.managedresource.crossplane.io"] }
        }));

        let text = describe_unsafe_delete(&state, "k3d-mgmt", "clusters.x.io", "prod");

        assert!(text.contains("external-name='<missing>'"), "{text}");
        assert!(text.contains("crossplane-finalizer=true"), "{text}");
        assert!(text.contains("clusters.x.io/prod"), "{text}");
        assert!(text.contains("--context k3d-mgmt"), "{text}");
    }

    #[test]
    fn the_runbook_offers_the_finalizer_strip_when_the_cloud_resource_is_gone() {
        let state = ManagedState::of(&json!({}));

        let text = describe_unsafe_delete(&state, "ctx", "clusters.x.io", "prod");

        assert!(text.contains(r#"{"metadata":{"finalizers":[]}}"#), "{text}");
    }
}

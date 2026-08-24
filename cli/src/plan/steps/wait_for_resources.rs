use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use console::style;
use serde_json::Value;

use crate::domain::plan::WaitForResourcesParams;
use crate::io::kubectl::Kubectl;
use crate::plan::StepContext;

pub async fn run(sctx: &StepContext<'_>, p: &WaitForResourcesParams) -> Result<()> {
    let WaitForResourcesParams {
        target,
        resources,
        wait_timeout_seconds,
        kube_context: kube_context_override,
    } = p;
    let kube_context_override = kube_context_override.as_deref();

    let context = kube_context_override
        .map(String::from)
        .map(Ok)
        .unwrap_or_else(|| sctx.lab.kube_context(target).map(String::from))?;
    for resource in resources {
        if resource["kind"].as_str().is_some() {
            wait_kubectl(sctx.kubectl, target, &context, resource)?;
        } else {
            let default_timeout = wait_timeout_seconds.unwrap_or(600);
            wait_crossplane_managed(sctx.kubectl, &context, resource, default_timeout).await?;
        }
    }
    Ok(())
}

fn wait_kubectl(
    kubectl: &dyn Kubectl,
    target: &str,
    context: &str,
    resource: &Value,
) -> Result<()> {
    let kind = resource["kind"].as_str().unwrap_or_default();
    let condition = resource["condition"].as_str().unwrap_or("Ready");
    let timeout = resource["timeout"].as_str().unwrap_or("10m");
    let namespace = resource["namespace"].as_str();
    let name = resource["name"].as_str();
    let selector = resource["labelSelector"].as_str();

    let mut args: Vec<String> = vec!["wait".into()];
    if let Some(ns) = namespace {
        args.push("-n".into());
        args.push(ns.into());
    }
    let kind_lower = kind.to_lowercase();
    match (name, selector) {
        (Some(n), None) => args.push(format!("{kind_lower}/{n}")),
        (None, Some(s)) => {
            args.push(kind_lower);
            args.push("-l".into());
            args.push(s.into());
        }
        (Some(_), Some(_)) => {
            bail!("wait-for-resources entry sets both `name` and `labelSelector`; choose one")
        }
        (None, None) => bail!(
            "wait-for-resources entry must set `name` or `labelSelector` when `kind` is present"
        ),
    }
    args.push(format!("--for=condition={condition}"));
    args.push(format!("--timeout={timeout}"));

    let descr = name.or(selector).unwrap_or("?");
    println!(
        "{} Waiting for {}/{} on '{}' (condition={})...",
        style(">>>").cyan(),
        kind,
        descr,
        target,
        condition,
    );

    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let ok = kubectl
        .run_streaming(context, &args)
        .with_context(|| format!("running kubectl wait for {kind}/{descr}"))?;
    if !ok {
        bail!("Timed out or failed waiting for {kind}/{descr} on '{target}'");
    }
    println!("{} {}/{} ready", style(">>>").green(), kind, descr);
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Readiness {
    Ready,
    NotReady,
    CannotTell,
}

pub fn classify_readiness(status_ok: bool, stdout: &str) -> Readiness {
    match (status_ok, stdout.trim()) {
        (false, _) => Readiness::CannotTell,
        (true, "True") => Readiness::Ready,
        (true, _) => Readiness::NotReady,
    }
}

async fn wait_crossplane_managed(
    kubectl: &dyn Kubectl,
    context: &str,
    resource: &Value,
    timeout_secs: u64,
) -> Result<()> {
    let res_name = resource["name"].as_str().ok_or_else(|| {
        anyhow::anyhow!(
            "a wait-for-resources step named no resource. The field selector \
             built from it would match nothing and this would wait out the \
             full {timeout_secs}s before reporting a cluster timeout for what \
             is a planner bug. Run `cata lab plan` to see the step"
        )
    })?;
    println!(
        "{} Waiting for '{res_name}' to be ready...",
        style(">>>").cyan(),
    );
    let start = Instant::now();
    let timeout = Duration::from_secs(timeout_secs);
    loop {
        let observed = kubectl.run(
            context,
            &[
                "get",
                "managed",
                "--field-selector",
                &format!("metadata.name={res_name}"),
                "-o",
                "jsonpath={.items[0].status.conditions[?(@.type==\"Ready\")].status}",
            ],
        );
        let verdict = match &observed {
            Ok(o) => classify_readiness(o.status_ok, &o.text()),
            Err(_) => Readiness::CannotTell,
        };
        if verdict == Readiness::Ready {
            println!("{} '{res_name}' is ready", style(">>>").green());
            return Ok(());
        }
        if start.elapsed() > timeout {
            match verdict {
                Readiness::CannotTell => bail!(
                    "gave up waiting for '{res_name}': kubectl never answered \
                     successfully, so whether it is ready is unknown"
                ),
                _ => bail!("Timed out waiting for '{res_name}' to be ready"),
            }
        }
        println!("  waiting... ({}s elapsed)", start.elapsed().as_secs());
        tokio::time::sleep(tokio::time::Duration::from_secs(15)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::io::kubectl::KubectlRun;
    use crate::io::kubectl::seam::fake::FakeKubectl;
    use serde_json::json;

    #[test]
    fn a_true_condition_is_ready() {
        assert_eq!(classify_readiness(true, "True"), Readiness::Ready);
        assert_eq!(classify_readiness(true, "  True\n"), Readiness::Ready);
    }

    #[test]
    fn a_false_condition_is_not_ready() {
        assert_eq!(classify_readiness(true, "False"), Readiness::NotReady);
        assert_eq!(classify_readiness(true, ""), Readiness::NotReady);
    }

    // A kubectl that failed says nothing about readiness. Reading its empty
    // stdout as "not ready yet" is how a broken query became a cluster
    // timeout.
    #[test]
    fn a_failing_kubectl_is_not_evidence_of_being_unready() {
        assert_eq!(classify_readiness(false, ""), Readiness::CannotTell);
        assert_eq!(classify_readiness(false, "True"), Readiness::CannotTell);
    }

    #[tokio::test]
    async fn a_step_that_names_no_resource_fails_at_once_rather_than_waiting() {
        let kubectl = FakeKubectl::new().otherwise(KubectlRun::ok(""));
        let started = Instant::now();

        let err = wait_crossplane_managed(&kubectl, "k3d-app", &json!({}), 600)
            .await
            .expect_err("a nameless resource must not be waited on");

        assert!(
            started.elapsed() < Duration::from_secs(1),
            "it waited instead of failing"
        );
        assert!(err.to_string().contains("planner bug"), "{err}");
        assert!(
            !kubectl.ran(&["get", "managed"]),
            "it should not have asked the cluster anything"
        );
    }

    #[tokio::test]
    async fn a_ready_resource_is_not_waited_on() {
        let kubectl = FakeKubectl::new().otherwise(KubectlRun::ok("True"));
        let resource = json!({ "name": "cluster-0" });

        wait_crossplane_managed(&kubectl, "k3d-app", &resource, 600)
            .await
            .expect("a resource reporting True is ready");

        assert!(kubectl.ran(&["get", "managed"]));
    }

    #[tokio::test]
    async fn a_kubectl_that_never_answers_says_so_rather_than_blaming_the_resource() {
        let kubectl = FakeKubectl::new().otherwise(KubectlRun::failed("no such context"));
        let resource = json!({ "name": "cluster-0" });

        let err = wait_crossplane_managed(&kubectl, "k3d-app", &resource, 0)
            .await
            .expect_err("a failing kubectl must not read as ready");

        assert!(
            err.to_string().contains("never answered"),
            "the message should distinguish 'cannot tell' from 'not ready': {err}"
        );
    }

    #[tokio::test]
    async fn the_empty_context_bug_cannot_come_back_here() {
        let kubectl = FakeKubectl::new().otherwise(KubectlRun::ok("True"));
        let resource = json!({ "name": "cluster-0" });

        let panicked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _ = kubectl.run("", &["get", "managed"]);
        }));

        assert!(panicked.is_err(), "an empty context must trip the fake");
        let _ = resource;
    }
}

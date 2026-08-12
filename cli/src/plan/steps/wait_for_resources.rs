use std::process::Command;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use console::style;
use serde_json::Value;

use crate::commands::lab::state::resolve_cluster_context;
use crate::plan::StepContext;

pub async fn run(
    sctx: &StepContext<'_>,
    target: &str,
    resources: &[Value],
    wait_timeout_seconds: Option<u64>,
    kube_context_override: Option<&str>,
) -> Result<()> {
    let context = kube_context_override
        .map(String::from)
        .unwrap_or_else(|| resolve_cluster_context(sctx.lab, target));
    for resource in resources {
        if resource["kind"].as_str().is_some() {
            wait_kubectl(target, &context, resource)?;
        } else {
            let default_timeout = wait_timeout_seconds.unwrap_or(600);
            wait_crossplane_managed(&context, resource, default_timeout).await?;
        }
    }
    Ok(())
}

fn wait_kubectl(target: &str, context: &str, resource: &Value) -> Result<()> {
    let kind = resource["kind"].as_str().unwrap_or_default();
    let condition = resource["condition"].as_str().unwrap_or("Ready");
    let timeout = resource["timeout"].as_str().unwrap_or("10m");
    let namespace = resource["namespace"].as_str();
    let name = resource["name"].as_str();
    let selector = resource["labelSelector"].as_str();

    let mut args: Vec<String> = vec!["--context".into(), context.to_string(), "wait".into()];
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

    let status = Command::new("kubectl")
        .args(&args)
        .status()
        .with_context(|| format!("running kubectl wait for {kind}/{descr}"))?;
    if !status.success() {
        bail!("Timed out or failed waiting for {kind}/{descr} on '{target}'");
    }
    println!("{} {}/{} ready", style(">>>").green(), kind, descr);
    Ok(())
}

async fn wait_crossplane_managed(context: &str, resource: &Value, timeout_secs: u64) -> Result<()> {
    let res_name = resource["name"].as_str().unwrap_or("?");
    println!(
        "{} Waiting for '{res_name}' to be ready...",
        style(">>>").cyan(),
    );
    let start = Instant::now();
    let timeout = Duration::from_secs(timeout_secs);
    loop {
        let output = Command::new("kubectl")
            .args([
                "--context",
                context,
                "get",
                "managed",
                "--field-selector",
                &format!("metadata.name={res_name}"),
                "-o",
                "jsonpath={.items[0].status.conditions[?(@.type==\"Ready\")].status}",
            ])
            .output();
        if let Ok(ref o) = output
            && String::from_utf8_lossy(&o.stdout).trim() == "True"
        {
            println!("{} '{res_name}' is ready", style(">>>").green());
            return Ok(());
        }
        if start.elapsed() > timeout {
            bail!("Timed out waiting for '{res_name}' to be ready");
        }
        println!("  waiting... ({}s elapsed)", start.elapsed().as_secs());
        tokio::time::sleep(tokio::time::Duration::from_secs(15)).await;
    }
}

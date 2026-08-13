use std::process::Command;

use anyhow::{Context, Result, bail};
use console::style;

use crate::config::Context as CataContext;
use crate::io;
use crate::io::process::run_capture;

pub fn sync_kubeconfig(ctx: &CataContext, mgmt_context: &str, cluster_name: &str) -> Result<()> {
    let (secret_name, secret_ns) = connection_secret_ref(ctx, mgmt_context, cluster_name)?;
    let kubeconfig = read_connection_kubeconfig(ctx, mgmt_context, &secret_name, &secret_ns)?;
    let kube_dir = dirs::home_dir().unwrap_or_default().join(".kube");
    std::fs::create_dir_all(&kube_dir)?;
    let kube_path = kube_dir.join(format!("{cluster_name}.kubeconfig"));
    std::fs::write(&kube_path, kubeconfig.as_bytes())?;

    let mut current = Command::new("kubectl");
    current
        .env("KUBECONFIG", kube_path.display().to_string())
        .args(["config", "current-context"]);
    let orig_ctx = run_capture(&mut current, ctx)
        .ok()
        .map(|o| o.trim().to_string());

    if let Some(ref orig) = orig_ctx
        && orig != cluster_name
    {
        let mut rename = Command::new("kubectl");
        rename
            .env("KUBECONFIG", kube_path.display().to_string())
            .args(["config", "rename-context", orig, cluster_name]);
        let _ = run_capture(&mut rename, ctx);
    }

    io::kubectl::merge_kubeconfig(&kube_path, cluster_name)?;

    Ok(())
}

fn connection_secret_ref(
    ctx: &CataContext,
    mgmt_context: &str,
    cluster_name: &str,
) -> Result<(String, String)> {
    let cluster_kinds = [
        "clusters.kubernetes.digitalocean.crossplane.io",
        "clusters.eks.aws.upbound.io",
        "clusters.container.gcp.upbound.io",
    ];

    let mut cr_json: Option<serde_json::Value> = None;
    for kind in cluster_kinds {
        let mut cmd = Command::new("kubectl");
        cmd.args([
            "--context",
            mgmt_context,
            "get",
            kind,
            cluster_name,
            "-o",
            "json",
        ]);
        if let Ok(out) = run_capture(&mut cmd, ctx)
            && let Ok(v) = serde_json::from_str::<serde_json::Value>(&out)
        {
            cr_json = Some(v);
            break;
        }
    }

    let cr = cr_json.ok_or_else(|| {
        anyhow::anyhow!(
            "No Crossplane cluster CR named '{cluster_name}' found on context '{mgmt_context}'"
        )
    })?;

    let conn_ref = cr
        .pointer("/spec/writeConnectionSecretToRef")
        .ok_or_else(|| {
            anyhow::anyhow!(
                "Cluster CR '{cluster_name}' has no spec.writeConnectionSecretToRef; \
                 cannot locate connection secret"
            )
        })?;
    let secret_name = conn_ref
        .get("name")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow::anyhow!("writeConnectionSecretToRef.name missing"))?;
    let secret_ns = conn_ref
        .get("namespace")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow::anyhow!("writeConnectionSecretToRef.namespace missing"))?;

    Ok((secret_name.to_string(), secret_ns.to_string()))
}

fn read_connection_kubeconfig(
    ctx: &CataContext,
    mgmt_context: &str,
    secret_name: &str,
    secret_ns: &str,
) -> Result<String> {
    let mut cmd = Command::new("kubectl");
    cmd.args([
        "--context",
        mgmt_context,
        "get",
        "secret",
        secret_name,
        "-n",
        secret_ns,
        "-o",
        "json",
    ]);
    let secret_output = run_capture(&mut cmd, ctx).with_context(|| {
        format!(
            "reading connection secret {secret_ns}/{secret_name}; \
             is the Crossplane resource Synced+Ready?"
        )
    })?;

    let secret_json: serde_json::Value = serde_json::from_str(&secret_output)
        .with_context(|| format!("Failed to parse connection secret {secret_ns}/{secret_name}"))?;
    let data = secret_json
        .get("data")
        .and_then(|v| v.as_object())
        .ok_or_else(|| {
            anyhow::anyhow!("Connection secret {secret_ns}/{secret_name} has no data field yet")
        })?;

    let known_keys = [
        "kubeconfig",
        "attribute.kube_config.0.raw_config",
        "attribute.kubeconfig",
    ];
    let kubeconfig_b64 = known_keys
        .iter()
        .find_map(|k| data.get(*k).and_then(|v| v.as_str()))
        .ok_or_else(|| {
            anyhow::anyhow!(
                "Connection secret {secret_ns}/{secret_name} has none of the known \
             kubeconfig keys ({}); available keys: {}",
                known_keys.join(", "),
                data.keys().cloned().collect::<Vec<_>>().join(", "),
            )
        })?;

    let kubeconfig_bytes =
        base64::Engine::decode(&base64::engine::general_purpose::STANDARD, kubeconfig_b64)
            .context("Failed to base64-decode kubeconfig from connection secret")?;
    let kubeconfig = String::from_utf8_lossy(&kubeconfig_bytes);
    if !kubeconfig.contains("apiVersion") {
        bail!("Connection secret {secret_ns}/{secret_name} kubeconfig entry is not valid YAML");
    }

    Ok(kubeconfig.to_string())
}

struct Target {
    kind: String,
    name: String,
    discovery_bin: Option<String>,
}

pub fn reconcile_managed_resource(
    ctx: &CataContext,
    kube_ctx: &str,
    resource_kind: &str,
    resource_name: &str,
    discovery_bin: Option<&str>,
) -> Result<()> {
    if resource_kind.is_empty() || resource_name.is_empty() || kube_ctx.is_empty() {
        bail!(
            "reconcile-managed-resource needs a kind, a name and a context, \
             got kind='{resource_kind}' name='{resource_name}' context='{kube_ctx}'"
        );
    }

    let target = Target {
        kind: resource_kind.to_string(),
        name: resource_name.to_string(),
        discovery_bin: discovery_bin.map(String::from),
    };
    reconcile_context(ctx, kube_ctx, std::slice::from_ref(&target));
    Ok(())
}

fn try_discover_and_annotate(
    cata: &CataContext,
    kube_ctx: &str,
    kind: &str,
    name: &str,
    bin: &str,
) -> bool {
    println!(
        "{} Reconcile: {}/{} missing external-name; running discovery {}",
        style(">>>").yellow(),
        kind,
        name,
        bin,
    );
    let mut discovery = Command::new(bin);
    discovery.env("KUBECONTEXT", kube_ctx).env("MR_NAME", name);
    crate::io::trust::apply(&mut discovery);
    let out = match discovery.output() {
        Ok(o) => o,
        Err(e) => {
            println!(
                "{} Reconcile: discovery binary {} failed to spawn: {}",
                style(">>>").yellow(),
                bin,
                e,
            );
            return false;
        }
    };
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        println!(
            "{} Reconcile: discovery for {}/{} exited {}: {}",
            style(">>>").yellow(),
            kind,
            name,
            out.status.code().unwrap_or(-1),
            stderr.trim(),
        );
        return false;
    }
    let discovered = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if discovered.is_empty() {
        println!(
            "{} Reconcile: discovery for {}/{} succeeded but emitted empty output",
            style(">>>").yellow(),
            kind,
            name,
        );
        return false;
    }
    let mut annotate = Command::new("kubectl");
    annotate.args([
        "--context",
        kube_ctx,
        "annotate",
        &format!("{kind}/{name}"),
        &format!("crossplane.io/external-name={discovered}"),
        "--overwrite",
    ]);
    match run_capture(&mut annotate, cata) {
        Ok(_) => {
            println!(
                "{} Reconcile: {}/{} adopted (external-name={})",
                style(">>>").green(),
                kind,
                name,
                discovered,
            );
            let _ = io::kubectl::wait_managed_ready(kube_ctx, 60);
            true
        }
        Err(_) => {
            println!(
                "{} Reconcile: kubectl annotate failed for {}/{}",
                style(">>>").yellow(),
                kind,
                name,
            );
            false
        }
    }
}

fn reconcile_context(cata: &CataContext, ctx: &str, targets: &[Target]) {
    if !io::kubectl::api_reachable(ctx) {
        println!(
            "{} Reconcile: context '{}' unreachable, leaving CRs to the plan's preflight",
            style(">>>").yellow(),
            ctx
        );
        return;
    }
    for t in targets {
        let Target {
            kind,
            name,
            discovery_bin,
        } = t;
        let mut get = Command::new("kubectl");
        get.args([
            "--context",
            ctx,
            "get",
            &format!("{kind}/{name}"),
            "-o",
            "json",
        ]);
        let cr = run_capture(&mut get, cata)
            .ok()
            .and_then(|o| serde_json::from_str::<serde_json::Value>(&o).ok());
        let cr = match cr {
            Some(v) => v,
            None => continue,
        };

        let external_name_ok = cr
            .pointer("/metadata/annotations/crossplane.io~1external-name")
            .and_then(|v| v.as_str())
            .map(|s| !s.is_empty())
            .unwrap_or(false);
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

        if external_name_ok && has_xp_finalizer {
            continue;
        }

        if !external_name_ok
            && let Some(bin) = discovery_bin.as_deref()
            && try_discover_and_annotate(cata, ctx, kind, name, bin)
        {
            continue;
        }

        println!(
            "{} Reconcile: {}/{} state drifted (external-name={}, finalizer={}). Nudging Crossplane via crossplane.io/paused toggle…",
            style(">>>").yellow(),
            kind,
            name,
            if external_name_ok { "ok" } else { "missing" },
            if has_xp_finalizer { "ok" } else { "missing" },
        );
        let mut pause = Command::new("kubectl");
        pause.args([
            "--context",
            ctx,
            "annotate",
            &format!("{kind}/{name}"),
            "crossplane.io/paused=true",
            "--overwrite",
        ]);
        let _ = run_capture(&mut pause, cata);
        std::thread::sleep(std::time::Duration::from_secs(3));
        let mut unpause = Command::new("kubectl");
        unpause.args([
            "--context",
            ctx,
            "annotate",
            &format!("{kind}/{name}"),
            "crossplane.io/paused-",
        ]);
        let _ = run_capture(&mut unpause, cata);
        let _ = io::kubectl::wait_managed_ready(ctx, 60);
    }
}

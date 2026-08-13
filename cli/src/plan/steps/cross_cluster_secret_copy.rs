use std::io::Write as _;
use std::process::{Command, Stdio};

use anyhow::{Result, bail};
use console::style;
use serde_json::Value;

use crate::domain::plan::CrossClusterSecretCopyParams;
use crate::plan::StepContext;

pub async fn run(sctx: &StepContext<'_>, p: &CrossClusterSecretCopyParams) -> Result<()> {
    let CrossClusterSecretCopyParams {
        name: _,
        source_cluster: src_cluster,
        source_namespace: src_namespace,
        source_secret: src_secret,
        target_cluster: tgt_cluster,
        target_namespace: tgt_namespace,
        target_secret: tgt_secret,
        secret_type: override_type,
        source_context,
        target_context,
    } = p;
    let override_type = override_type.as_deref();
    let source_context = source_context.as_deref();
    let target_context = target_context.as_deref();

    let src_ctx = source_context
        .map(String::from)
        .map(Ok)
        .unwrap_or_else(|| sctx.lab.kube_context(src_cluster).map(String::from))?;
    let tgt_ctx = target_context
        .map(String::from)
        .map(Ok)
        .unwrap_or_else(|| sctx.lab.kube_context(tgt_cluster).map(String::from))?;

    if sctx.dry_run {
        println!(
            "{} [dry-run] would copy secret '{}/{}' from '{}' to '{}/{}' on '{}'",
            style(">>>").yellow(),
            src_namespace,
            src_secret,
            src_cluster,
            tgt_namespace,
            tgt_secret,
            tgt_cluster,
        );
        return Ok(());
    }

    println!(
        "{} Waiting for source secret '{}/{}' on '{}'...",
        style(">>>").cyan(),
        src_namespace,
        src_secret,
        src_cluster,
    );
    let wait = Command::new("kubectl")
        .args([
            "--context",
            &src_ctx,
            "-n",
            src_namespace,
            "wait",
            "--for=create",
            &format!("secret/{src_secret}"),
            "--timeout=5m",
        ])
        .status()?;
    if !wait.success() {
        bail!(
            "Source secret '{src_namespace}/{src_secret}' did not appear on '{src_cluster}' within timeout",
        );
    }

    let secret_json = read_source_secret(
        &src_ctx,
        src_cluster,
        src_namespace,
        src_secret,
        tgt_namespace,
        tgt_secret,
        override_type,
    )?;
    write_target_secret(
        &tgt_ctx,
        tgt_namespace,
        tgt_secret,
        tgt_cluster,
        &secret_json,
    )?;

    println!(
        "{} Copied '{}/{}' from '{}' to '{}/{}' on '{}'",
        style(">>>").green(),
        src_namespace,
        src_secret,
        src_cluster,
        tgt_namespace,
        tgt_secret,
        tgt_cluster,
    );
    Ok(())
}

fn read_source_secret(
    src_ctx: &str,
    src_cluster: &str,
    src_namespace: &str,
    src_secret: &str,
    tgt_namespace: &str,
    tgt_secret: &str,
    override_type: Option<&str>,
) -> Result<Value> {
    let get_out = Command::new("kubectl")
        .args([
            "--context",
            src_ctx,
            "-n",
            src_namespace,
            "get",
            "secret",
            src_secret,
            "-o",
            "json",
        ])
        .output()?;
    if !get_out.status.success() {
        bail!(
            "kubectl get secret {src_secret} on '{src_cluster}' failed: {}",
            String::from_utf8_lossy(&get_out.stderr),
        );
    }
    let mut secret_json: Value = serde_json::from_slice(&get_out.stdout)?;

    if let Some(meta) = secret_json
        .get_mut("metadata")
        .and_then(|m| m.as_object_mut())
    {
        for k in [
            "creationTimestamp",
            "resourceVersion",
            "uid",
            "selfLink",
            "managedFields",
            "ownerReferences",
            "annotations",
        ] {
            meta.remove(k);
        }
        meta.insert("name".into(), Value::String(tgt_secret.to_string()));
        meta.insert("namespace".into(), Value::String(tgt_namespace.to_string()));
        meta.entry("labels")
            .or_insert(serde_json::json!({}))
            .as_object_mut()
            .expect("just inserted an empty object")
            .insert(
                "catallaxy.io/managed-by".into(),
                Value::String("cross-cluster-secret-copy".into()),
            );
    }
    if let Some(t) = override_type {
        secret_json["type"] = Value::String(t.to_string());
    }
    if let Some(obj) = secret_json.as_object_mut() {
        obj.remove("status");
    }

    Ok(secret_json)
}

fn write_target_secret(
    tgt_ctx: &str,
    tgt_namespace: &str,
    tgt_secret: &str,
    tgt_cluster: &str,
    secret_json: &Value,
) -> Result<()> {
    let _ = Command::new("kubectl")
        .args([
            "--context",
            tgt_ctx,
            "create",
            "namespace",
            tgt_namespace,
            "--dry-run=client",
            "-o",
            "yaml",
        ])
        .output()
        .and_then(|out| {
            let mut child = Command::new("kubectl")
                .args(["--context", tgt_ctx, "apply", "-f", "-"])
                .stdin(Stdio::piped())
                .spawn()?;
            if let Some(stdin) = child.stdin.as_mut() {
                stdin.write_all(&out.stdout)?;
            }
            child.wait()?;
            Ok(())
        });

    let mut apply = Command::new("kubectl")
        .args(["--context", tgt_ctx, "apply", "-f", "-"])
        .stdin(Stdio::piped())
        .spawn()?;
    apply
        .stdin
        .as_mut()
        .expect("stdin was piped in the command builder above")
        .write_all(secret_json.to_string().as_bytes())?;
    if !apply.wait()?.success() {
        bail!("kubectl apply of '{tgt_namespace}/{tgt_secret}' on '{tgt_cluster}' failed",);
    }
    Ok(())
}

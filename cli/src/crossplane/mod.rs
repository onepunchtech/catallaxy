use anyhow::{Context, Result, bail};
use console::style;

use crate::domain::crossplane::ManagedState;
use crate::io;

pub fn sync_kubeconfig(mgmt_context: &str, cluster_name: &str) -> Result<()> {
    let (secret_name, secret_ns) = connection_secret_ref(mgmt_context, cluster_name)?;
    let kubeconfig = read_connection_kubeconfig(mgmt_context, &secret_name, &secret_ns)?;
    let kube_dir = io::fs::home_dir()?.join(".kube");
    let kube_path = kube_dir.join(format!("{cluster_name}.kubeconfig"));
    io::fs::write_atomic(&kube_path, kubeconfig.as_bytes())?;

    let orig_ctx = io::kubectl::current_context_of(&kube_path);

    if let Some(ref orig) = orig_ctx
        && orig != cluster_name
    {
        io::kubectl::rename_context_in(&kube_path, orig, cluster_name);
    }

    io::kubectl::merge_kubeconfig(&kube_path, cluster_name)?;

    Ok(())
}

fn connection_secret_ref(mgmt_context: &str, cluster_name: &str) -> Result<(String, String)> {
    let cluster_kinds = [
        "clusters.kubernetes.digitalocean.crossplane.io",
        "clusters.eks.aws.upbound.io",
        "clusters.container.gcp.upbound.io",
    ];

    let mut cr_json: Option<serde_json::Value> = None;
    for kind in cluster_kinds {
        if let Ok(out) =
            io::kubectl::capture(mgmt_context, &["get", kind, cluster_name, "-o", "json"])
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
    mgmt_context: &str,
    secret_name: &str,
    secret_ns: &str,
) -> Result<String> {
    let secret_output = io::kubectl::capture(
        mgmt_context,
        &["get", "secret", secret_name, "-n", secret_ns, "-o", "json"],
    )
    .with_context(|| {
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
    reconcile_context(kube_ctx, std::slice::from_ref(&target))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiscoveryFailure {
    Exited { code: i32, stderr: String },
    EmptyOutput,
}

impl DiscoveryFailure {
    fn describe(&self, kind: &str, name: &str) -> String {
        match self {
            DiscoveryFailure::Exited { code, stderr } => {
                format!("Reconcile: discovery for {kind}/{name} exited {code}: {stderr}")
            }
            DiscoveryFailure::EmptyOutput => {
                format!("Reconcile: discovery for {kind}/{name} succeeded but emitted empty output")
            }
        }
    }
}

fn interpret_discovery(out: &std::process::Output) -> Result<String, DiscoveryFailure> {
    if !out.status.success() {
        return Err(DiscoveryFailure::Exited {
            code: out.status.code().unwrap_or(-1),
            stderr: String::from_utf8_lossy(&out.stderr).trim().to_string(),
        });
    }

    let discovered = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if discovered.is_empty() {
        return Err(DiscoveryFailure::EmptyOutput);
    }
    Ok(discovered)
}

fn try_discover_and_annotate(kube_ctx: &str, kind: &str, name: &str, bin: &str) -> bool {
    println!(
        "{} Reconcile: {}/{} missing external-name; running discovery {}",
        style(">>>").yellow(),
        kind,
        name,
        bin,
    );
    let out = match io::discovery::run(bin, kube_ctx, name) {
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

    let discovered = match interpret_discovery(&out) {
        Ok(d) => d,
        Err(failure) => {
            println!("{} {}", style(">>>").yellow(), failure.describe(kind, name));
            return false;
        }
    };

    match io::kubectl::annotate(
        kube_ctx,
        &format!("{kind}/{name}"),
        &format!("crossplane.io/external-name={discovered}"),
        true,
    ) {
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

fn reconcile_context(ctx: &str, targets: &[Target]) -> Result<()> {
    if !io::kubectl::api_reachable(ctx) {
        println!(
            "{} Reconcile: context '{}' unreachable, leaving CRs to the plan's preflight",
            style(">>>").yellow(),
            ctx
        );
        return Ok(());
    }
    for t in targets {
        let Target {
            kind,
            name,
            discovery_bin,
        } = t;
        let cr = io::kubectl::resource_json(ctx, &format!("{kind}/{name}"));
        let cr = match cr {
            Some(v) => v,
            None => continue,
        };

        let state = ManagedState::of(&cr);
        let external_name_ok = state.external_name.is_some();
        let has_xp_finalizer = state.has_finalizer;

        if state.is_deletable() {
            continue;
        }

        if !external_name_ok
            && let Some(bin) = discovery_bin.as_deref()
            && try_discover_and_annotate(ctx, kind, name, bin)
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
        let resource = format!("{kind}/{name}");
        if io::kubectl::annotate(ctx, &resource, "crossplane.io/paused=true", true).is_err() {
            continue;
        }
        std::thread::sleep(std::time::Duration::from_secs(3));
        io::kubectl::annotate(ctx, &resource, "crossplane.io/paused-", false).with_context(
            || {
                format!(
                    "{resource} on '{ctx}' was paused to force a reconcile and could not be \
                     unpaused. Crossplane will not reconcile it again until it is, and \
                     nothing else clears the annotation. Run:\n    \
                     kubectl --context {ctx} annotate {resource} crossplane.io/paused-"
                )
            },
        )?;
        let _ = io::kubectl::wait_managed_ready(ctx, 60);
    }
    Ok(())
}

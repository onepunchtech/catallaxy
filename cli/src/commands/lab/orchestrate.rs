#![allow(unused_imports)]

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use anyhow::{Context, Result, bail};
use console::style;

use crate::commands::kubeconfig;
use crate::config::Context as CataContext;
use crate::io;

use super::{dns, orchestrate, pki, publish, services, state};

pub fn strip_finalizers_in_terminating_namespaces(kube_ctx: &str, namespaces: &[String]) {
    let crd_out = std::process::Command::new("kubectl")
        .args([
            "--context",
            kube_ctx,
            "get",
            "crd",
            "-o",
            r#"jsonpath={range .items[?(@.spec.scope=="Namespaced")]}{.spec.names.plural}.{.spec.group}{"\n"}{end}"#,
        ])
        .output();
    let crd_names: Vec<String> = crd_out
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
        .unwrap_or_default()
        .lines()
        .filter(|l| !l.is_empty())
        .map(String::from)
        .collect();

    for kind in &crd_names {
        for ns in namespaces {
            let inst_out = std::process::Command::new("kubectl")
                .args([
                    "--context",
                    kube_ctx,
                    "-n",
                    ns,
                    "get",
                    kind,
                    "-o",
                    "jsonpath={.items[*].metadata.name}",
                ])
                .output();
            let names: Vec<String> = inst_out
                .ok()
                .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
                .unwrap_or_default()
                .split_whitespace()
                .map(String::from)
                .collect();
            if names.is_empty() {
                continue;
            }
            for name in &names {
                let status = std::process::Command::new("kubectl")
                    .args([
                        "--context",
                        kube_ctx,
                        "-n",
                        ns,
                        "patch",
                        &format!("{kind}/{name}"),
                        "--type=merge",
                        "-p",
                        r#"{"metadata":{"finalizers":[]}}"#,
                    ])
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .status();
                if let Ok(s) = status {
                    if s.success() {
                        println!(
                            "{}   stripped finalizers: {}/{}/{}",
                            style(">>>").dim(),
                            ns,
                            kind,
                            name
                        );
                    }
                }
            }
        }
    }
}

pub fn publish_one_image(
    lab: &serde_json::Value,
    _src_cluster: &str,
    img: &serde_json::Value,
) -> Result<()> {
    let name = img["name"].as_str().unwrap_or("?");
    let raw_source = img["source"]
        .as_str()
        .ok_or_else(|| anyhow::anyhow!("image '{name}': missing source"))?;
    let attr = img["attr"]
        .as_str()
        .ok_or_else(|| anyhow::anyhow!("image '{name}': missing attr"))?;

    let source = if raw_source.starts_with('/') && !raw_source.contains(':') {
        format!("path:{raw_source}")
    } else {
        raw_source.to_string()
    };
    let also_latest = img["alsoLatest"].as_bool().unwrap_or(false);
    let destination = img["destination"]
        .as_str()
        .ok_or_else(|| anyhow::anyhow!("image '{name}': missing destination"))?;
    let dest_registry = img["destinationRegistry"].as_str().unwrap_or("");

    let tag = if let Some(t) = img["tag"].as_str() {
        t.to_string()
    } else {
        let tag_from = img["tagFrom"].as_str().unwrap_or(name);
        let versions_attr = format!("{source}#versions-json");
        println!(
            "{} Resolving tag for '{}' from {}",
            style(">>>").cyan(),
            name,
            versions_attr,
        );
        let out = std::process::Command::new("nix")
            .args(["build", "--no-link", "--print-out-paths", &versions_attr])
            .output()
            .context("Failed to run nix build for versions-json")?;
        if !out.status.success() {
            bail!(
                "image '{name}': nix build {versions_attr} failed: {}",
                String::from_utf8_lossy(&out.stderr),
            );
        }
        let versions_path = String::from_utf8_lossy(&out.stdout).trim().to_string();
        let versions_raw = fs::read_to_string(&versions_path)
            .with_context(|| format!("reading {versions_path}"))?;
        let versions: serde_json::Value = serde_json::from_str(&versions_raw)
            .with_context(|| format!("parsing {versions_path} as JSON"))?;
        versions[tag_from]
            .as_str()
            .ok_or_else(|| {
                anyhow::anyhow!("image '{name}': versions-json has no string at key '{tag_from}'",)
            })?
            .to_string()
    };

    let image_attr = format!("{source}#{attr}");
    println!("{} Building image: {}", style(">>>").cyan(), image_attr);
    let out = std::process::Command::new("nix")
        .args(["build", "--no-link", "--print-out-paths", &image_attr])
        .output()
        .context("Failed to run nix build")?;
    if !out.status.success() {
        bail!(
            "image '{name}': nix build {image_attr} failed: {}",
            String::from_utf8_lossy(&out.stderr),
        );
    }
    let archive_path = String::from_utf8_lossy(&out.stdout).trim().to_string();
    println!("   built: {archive_path}");

    let mut tarball_path = archive_path.clone();
    let _decompressed: Option<tempfile::TempPath> = {
        let mut hdr = [0u8; 2];
        let is_gz = {
            use std::io::Read;
            fs::File::open(&archive_path)
                .ok()
                .and_then(|mut f| f.read_exact(&mut hdr).ok())
                .is_some()
                && hdr == [0x1f, 0x8b]
        };
        if is_gz {
            let tmp = tempfile::Builder::new()
                .prefix("cata-publish-")
                .suffix(".tar")
                .tempfile()
                .context("creating tempfile for decompressed tarball")?;
            let tmp_path = tmp.into_temp_path();
            let outfile = fs::File::create(&tmp_path)?;
            let status = std::process::Command::new("gunzip")
                .arg("-c")
                .arg(&archive_path)
                .stdout(outfile)
                .status()
                .context("running gunzip")?;
            if !status.success() {
                bail!("image '{name}': gunzip of {archive_path} failed");
            }
            tarball_path = tmp_path.to_string_lossy().into_owned();
            Some(tmp_path)
        } else {
            None
        }
    };

    let docker_config_dir: Option<tempfile::TempDir> = match img["credentials"].as_object() {
        None => None,
        Some(creds) => {
            let cred_cluster = creds["cluster"].as_str().unwrap_or_default();
            let cred_namespace = creds["namespace"].as_str().unwrap_or("harbor");
            let cred_secret = creds["secretName"].as_str().unwrap_or_default();
            let cred_ctx = state::resolve_cluster_context(lab, cred_cluster);

            println!(
                "{} Fetching push credentials from '{}/{}' on '{}'",
                style(">>>").cyan(),
                cred_namespace,
                cred_secret,
                cred_cluster,
            );
            let _ = std::process::Command::new("kubectl")
                .args([
                    "--context",
                    &cred_ctx,
                    "-n",
                    cred_namespace,
                    "wait",
                    "--for=create",
                    &format!("secret/{cred_secret}"),
                    "--timeout=2m",
                ])
                .status();

            let dockercfg_out = std::process::Command::new("kubectl")
                .args([
                    "--context",
                    &cred_ctx,
                    "-n",
                    cred_namespace,
                    "get",
                    "secret",
                    cred_secret,
                    "-o",
                    "jsonpath={.data.\\.dockerconfigjson}",
                ])
                .output()?;
            if !dockercfg_out.status.success() {
                bail!(
                    "image '{name}': kubectl get secret '{cred_secret}' failed: {}",
                    String::from_utf8_lossy(&dockercfg_out.stderr),
                );
            }
            let b64 = String::from_utf8_lossy(&dockercfg_out.stdout)
                .trim()
                .to_string();
            if b64.is_empty() {
                bail!("image '{name}': dockerconfigjson is empty");
            }
            use base64::Engine;
            let json_bytes = base64::engine::general_purpose::STANDARD
                .decode(b64.as_bytes())
                .context("base64-decoding dockerconfigjson")?;
            let tmp = tempfile::tempdir().context("creating temp DOCKER_CONFIG dir")?;
            fs::write(tmp.path().join("config.json"), &json_bytes)
                .context("writing temp config.json")?;
            let cfg: serde_json::Value =
                serde_json::from_slice(&json_bytes).context("parsing dockerconfigjson")?;
            let has_entry = cfg["auths"]
                .as_object()
                .map(|m| {
                    m.keys().any(|k| {
                        let stripped = k
                            .trim_start_matches("https://")
                            .trim_start_matches("http://")
                            .trim_end_matches("/v1/")
                            .trim_end_matches('/');
                        stripped == dest_registry
                    })
                })
                .unwrap_or(false);
            if !has_entry {
                bail!("image '{name}': dockerconfigjson has no auth entry for '{dest_registry}'",);
            }
            Some(tmp)
        }
    };

    crate::io::process::check_tool("crane")?;
    let mut tags = vec![tag.clone()];
    if also_latest {
        tags.push("latest".to_string());
    }
    for t in &tags {
        let dest = format!("{destination}:{t}");
        println!("{} Pushing {} → {}", style(">>>").cyan(), name, dest);
        let mut cmd = std::process::Command::new("crane");
        cmd.args(["push", &tarball_path, &dest]);
        crate::io::trust::apply(&mut cmd);
        if let Some(d) = &docker_config_dir {
            cmd.env("DOCKER_CONFIG", d.path());
        }
        let status = cmd.status().context("running crane push")?;
        if !status.success() {
            bail!("image '{name}': crane push to {dest} failed");
        }
    }
    println!(
        "{} Published '{}' ({} tag(s))",
        style(">>>").green(),
        name,
        tags.len(),
    );
    Ok(())
}

pub async fn apply_cluster_components(
    ctx: &CataContext,
    cluster_name: &str,
    dry_run: bool,
    force: bool,
    manifests_dir: Option<String>,
    secrets_cache: Option<crate::commands::apply::SecretsCache>,
    lab_config: Option<&serde_json::Value>,
    kube_context_override: Option<String>,
) -> Result<()> {
    println!(
        "{} Applying manifests to cluster '{}'...",
        style(">>>").cyan(),
        cluster_name
    );

    crate::commands::apply::run(
        ctx,
        crate::commands::apply::ApplyArgs {
            cluster: Some(cluster_name.to_string()),
            bundle: None,
            dry_run,
            force,
            manifests_dir,
            secrets_cache,
            lab_config: lab_config.cloned(),
            kube_context_override,
        },
    )
    .await
}

pub fn import_lab_ca(lab_name: &str, lab: &serde_json::Value, cluster_name: &str) {
    let ingress_dir = state::service_state_dir(lab_name, "proxy");
    let ca_crt = ingress_dir.join("ca.crt");
    let ca_key = ingress_dir.join("ca.key");

    if !ca_crt.exists() || !ca_key.exists() {
        return;
    }

    let context = state::resolve_cluster_context(lab, cluster_name);

    let _ = std::process::Command::new("kubectl")
        .args(["--context", &context, "create", "namespace", "cert-manager"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();

    let _ = std::process::Command::new("kubectl")
        .args([
            "--context",
            &context,
            "delete",
            "secret",
            "lab-ca-ca-secret",
            "-n",
            "cert-manager",
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();

    let status = std::process::Command::new("kubectl")
        .args([
            "--context",
            &context,
            "create",
            "secret",
            "tls",
            "lab-ca-ca-secret",
            "-n",
            "cert-manager",
            "--cert",
        ])
        .arg(&ca_crt)
        .args(["--key"])
        .arg(&ca_key)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();

    match status {
        Ok(s) if s.success() => {
            println!(
                "{} Lab CA imported into '{cluster_name}'",
                style(">>>").green()
            );
        }
        _ => {
            println!(
                "{} Failed to import CA into '{cluster_name}'",
                style(">>>").yellow()
            );
        }
    }
}

pub fn sync_crossplane_kubeconfig(mgmt_context: &str, cluster_name: &str) -> Result<()> {
    let cluster_kinds = [
        "clusters.kubernetes.digitalocean.crossplane.io",
        "clusters.eks.aws.upbound.io",
        "clusters.container.gcp.upbound.io",
    ];

    let mut cr_json: Option<serde_json::Value> = None;
    for kind in cluster_kinds {
        let out = std::process::Command::new("kubectl")
            .args([
                "--context",
                mgmt_context,
                "get",
                kind,
                cluster_name,
                "-o",
                "json",
            ])
            .output();
        if let Ok(o) = out {
            if o.status.success() {
                if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&o.stdout) {
                    cr_json = Some(v);
                    break;
                }
            }
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

    let secret_output = std::process::Command::new("kubectl")
        .args([
            "--context",
            mgmt_context,
            "get",
            "secret",
            secret_name,
            "-n",
            secret_ns,
            "-o",
            "json",
        ])
        .output()
        .with_context(|| format!("Failed to read connection secret {secret_ns}/{secret_name}"))?;
    if !secret_output.status.success() {
        bail!(
            "Connection secret {secret_ns}/{secret_name} not found; \
             is the Crossplane resource Synced+Ready?"
        );
    }

    let secret_json: serde_json::Value = serde_json::from_slice(&secret_output.stdout)
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

    let kube_dir = dirs::home_dir().unwrap_or_default().join(".kube");
    std::fs::create_dir_all(&kube_dir)?;
    let kube_path = kube_dir.join(format!("{cluster_name}.kubeconfig"));
    std::fs::write(&kube_path, kubeconfig.as_bytes())?;

    let orig_ctx = std::process::Command::new("kubectl")
        .env("KUBECONFIG", kube_path.display().to_string())
        .args(["config", "current-context"])
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
            } else {
                None
            }
        });

    if let Some(ref orig) = orig_ctx {
        if orig != cluster_name {
            let _ = std::process::Command::new("kubectl")
                .env("KUBECONFIG", kube_path.display().to_string())
                .args(["config", "rename-context", orig, cluster_name])
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status();
        }
    }

    io::kubectl::merge_kubeconfig(&kube_path, cluster_name)?;

    Ok(())
}

pub fn reconcile_crossplane_state_for_teardown(steps: &[crate::domain::plan::PlannedStep]) {
    struct Target {
        kind: String,
        name: String,
        discovery_bin: Option<String>,
    }
    let mut targets: Vec<(String, Target)> = Vec::new();
    for step in steps {
        if let crate::domain::plan::StepParams::DeleteManagedResource {
            target,
            resource_kind,
            resource_name,
            kube_context,
            external_name_discovery_bin,
            ..
        } = &step.params
        {
            let ctx = kube_context.as_deref().unwrap_or(target.as_str());
            if !resource_kind.is_empty() && !ctx.is_empty() && !resource_name.is_empty() {
                targets.push((
                    ctx.to_string(),
                    Target {
                        kind: resource_kind.clone(),
                        name: resource_name.clone(),
                        discovery_bin: external_name_discovery_bin.clone(),
                    },
                ));
            }
        }
    }
    if targets.is_empty() {
        return;
    }

    let mut by_ctx: std::collections::BTreeMap<String, Vec<Target>> = Default::default();
    for (ctx, t) in targets {
        by_ctx.entry(ctx).or_default().push(t);
    }

    for (ctx, targets) in by_ctx {
        if !io::kubectl::api_reachable(&ctx) {
            println!(
                "{} Reconcile: context '{}' unreachable, leaving CRs to the plan's preflight",
                style(">>>").yellow(),
                ctx
            );
            continue;
        }
        for t in &targets {
            let Target {
                kind,
                name,
                discovery_bin,
            } = t;
            let cr = match std::process::Command::new("kubectl")
                .args([
                    "--context",
                    &ctx,
                    "get",
                    &format!("{kind}/{name}"),
                    "-o",
                    "json",
                ])
                .output()
            {
                Ok(o) if o.status.success() => {
                    serde_json::from_slice::<serde_json::Value>(&o.stdout).ok()
                }
                _ => None,
            };
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
                && try_discover_and_annotate(&ctx, kind, name, bin)
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
            let _ = std::process::Command::new("kubectl")
                .args([
                    "--context",
                    &ctx,
                    "annotate",
                    &format!("{kind}/{name}"),
                    "crossplane.io/paused=true",
                    "--overwrite",
                ])
                .stdout(std::process::Stdio::null())
                .status();
            std::thread::sleep(std::time::Duration::from_secs(3));
            let _ = std::process::Command::new("kubectl")
                .args([
                    "--context",
                    &ctx,
                    "annotate",
                    &format!("{kind}/{name}"),
                    "crossplane.io/paused-",
                ])
                .stdout(std::process::Stdio::null())
                .status();
            let _ = io::kubectl::wait_managed_ready(&ctx, 60);
        }
    }
}

fn try_discover_and_annotate(kube_ctx: &str, kind: &str, name: &str, bin: &str) -> bool {
    println!(
        "{} Reconcile: {}/{} missing external-name; running discovery {}",
        style(">>>").yellow(),
        kind,
        name,
        bin,
    );
    let out = match std::process::Command::new(bin)
        .env("KUBECONTEXT", kube_ctx)
        .env("MR_NAME", name)
        .output()
    {
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
    let annotate_status = std::process::Command::new("kubectl")
        .args([
            "--context",
            kube_ctx,
            "annotate",
            &format!("{kind}/{name}"),
            &format!("crossplane.io/external-name={discovered}"),
            "--overwrite",
        ])
        .stdout(std::process::Stdio::null())
        .status();
    match annotate_status {
        Ok(s) if s.success() => {
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
        _ => {
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

use std::fs;
use std::process::Command;

use anyhow::{Context, Result, bail};
use console::style;

use crate::config::Context as CataContext;
use crate::domain::LabSpec;
use crate::io::process::{run_capture, run_streaming};

pub fn publish_one(ctx: &CataContext, lab: &LabSpec, img: &serde_json::Value) -> Result<()> {
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
        let mut build = Command::new("nix");
        build.args(["build", "--no-link", "--print-out-paths", &versions_attr]);
        let versions_path = run_capture(&mut build, ctx)
            .with_context(|| format!("image '{name}': nix build {versions_attr}"))?
            .trim()
            .to_string();
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

    let (tarball_path, _decompressed) = build_image_archive(ctx, &source, attr, name)?;
    let docker_config_dir = image_credentials(ctx, img, name, dest_registry, lab)?;

    let mut tags = vec![tag.clone()];
    if also_latest {
        tags.push("latest".to_string());
    }
    for t in &tags {
        let dest = format!("{destination}:{t}");
        println!("{} Pushing {} → {}", style(">>>").cyan(), name, dest);
        let mut cmd = Command::new("crane");
        cmd.args(["push", &tarball_path, &dest]);
        if let Some(d) = &docker_config_dir {
            cmd.env("DOCKER_CONFIG", d.path());
        }
        run_streaming(&mut cmd, ctx)
            .with_context(|| format!("image '{name}': crane push to {dest}"))?;
    }
    println!(
        "{} Published '{}' ({} tag(s))",
        style(">>>").green(),
        name,
        tags.len(),
    );
    Ok(())
}

fn build_image_archive(
    ctx: &CataContext,
    source: &str,
    attr: &str,
    name: &str,
) -> Result<(String, Option<tempfile::TempPath>)> {
    let image_attr = format!("{source}#{attr}");
    println!("{} Building image: {}", style(">>>").cyan(), image_attr);
    let mut build = Command::new("nix");
    build.args(["build", "--no-link", "--print-out-paths", &image_attr]);
    let archive_path = run_capture(&mut build, ctx)
        .with_context(|| format!("image '{name}': nix build {image_attr}"))?
        .trim()
        .to_string();
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
            let status = Command::new("gunzip")
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

    Ok((tarball_path, _decompressed))
}

fn image_credentials(
    ctx: &CataContext,
    img: &serde_json::Value,
    name: &str,
    dest_registry: &str,
    lab: &LabSpec,
) -> Result<Option<tempfile::TempDir>> {
    let docker_config_dir: Option<tempfile::TempDir> = match img["credentials"].as_object() {
        None => None,
        Some(creds) => {
            let cred_cluster = creds["cluster"].as_str().unwrap_or_default();
            let cred_namespace = creds["namespace"].as_str().unwrap_or("harbor");
            let cred_secret = creds["secretName"].as_str().unwrap_or_default();
            let cred_ctx = lab.kube_context(cred_cluster)?;

            println!(
                "{} Fetching push credentials from '{}/{}' on '{}'",
                style(">>>").cyan(),
                cred_namespace,
                cred_secret,
                cred_cluster,
            );
            let mut wait = Command::new("kubectl");
            wait.args([
                "--context",
                cred_ctx,
                "-n",
                cred_namespace,
                "wait",
                "--for=create",
                &format!("secret/{cred_secret}"),
                "--timeout=2m",
            ]);
            let _ = run_capture(&mut wait, ctx);

            let mut get = Command::new("kubectl");
            get.args([
                "--context",
                cred_ctx,
                "-n",
                cred_namespace,
                "get",
                "secret",
                cred_secret,
                "-o",
                "jsonpath={.data.\\.dockerconfigjson}",
            ]);
            let b64 = run_capture(&mut get, ctx)
                .with_context(|| format!("image '{name}': reading secret '{cred_secret}'"))?
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
    Ok(docker_config_dir)
}

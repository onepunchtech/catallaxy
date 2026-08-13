use std::fs;
use std::path::Path;
use std::process::Command;

use anyhow::{Context, Result, bail};
use console::style;

use crate::config::Context as CataContext;
use crate::domain::LabSpec;
use crate::io::nix;
use crate::io::process::{run_capture, run_streaming};

pub fn publish_one(lab: &LabSpec, img: &serde_json::Value) -> Result<()> {
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
        let versions_path = run_capture(&mut build)
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

    let (tarball_path, _decompressed) = build_image_archive(&source, attr, name)?;
    let docker_config_dir = image_credentials(img, name, dest_registry, lab)?;

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
        run_streaming(&mut cmd).with_context(|| format!("image '{name}': crane push to {dest}"))?;
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
    source: &str,
    attr: &str,
    name: &str,
) -> Result<(String, Option<tempfile::TempPath>)> {
    let image_attr = format!("{source}#{attr}");
    println!("{} Building image: {}", style(">>>").cyan(), image_attr);
    let mut build = Command::new("nix");
    build.args(["build", "--no-link", "--print-out-paths", &image_attr]);
    let archive_path = run_capture(&mut build)
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
            let _ = run_capture(&mut wait);

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
            let b64 = run_capture(&mut get)
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

pub async fn warm_to_target_with(
    ctx: &CataContext,
    name: Option<&str>,
    target_registry: &str,
    lab: Option<&LabSpec>,
    lab_pkg: Option<&str>,
) -> Result<()> {
    let images = if let Some(pkg) = lab_pkg {
        load_image_list_from_package(pkg)?
    } else {
        load_image_list(ctx, name)?
    };

    let (upstreams, lab_owned) = match lab {
        Some(lab) => (
            lab.registry_upstreams.clone(),
            lab.lab_owned_registries.clone(),
        ),
        None => {
            let lab = crate::io::nix::get_lab_spec(ctx, &ctx.resolve_lab_name(name)?)?;
            (lab.registry_upstreams, lab.lab_owned_registries)
        }
    };

    println!(
        "{} Warming {} images via {}",
        style("catallaxy").cyan().bold(),
        images.len(),
        style(target_registry).bold(),
    );

    let base = if target_registry.contains("://") {
        target_registry.to_string()
    } else {
        let registry = target_registry.replace("localhost", "127.0.0.1");
        format!("http://{registry}")
    };

    let client = crate::io::http::client(
        reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(360))
            .user_agent("catallaxy-warm/0.1"),
    )?;

    use std::sync::Arc;
    use tokio::sync::{Mutex, Semaphore};
    let tags_cache: Arc<
        Mutex<std::collections::HashMap<String, std::collections::HashSet<String>>>,
    > = Arc::new(Mutex::new(std::collections::HashMap::new()));

    let concurrency = std::env::var("CATA_WARM_CONCURRENCY")
        .ok()
        .and_then(|s| s.parse::<usize>().ok())
        .filter(|n| *n > 0)
        .unwrap_or(8);
    let sem = Arc::new(Semaphore::new(concurrency));

    let base = Arc::new(base);
    let client = Arc::new(client);
    let upstreams = Arc::new(upstreams);
    let lab_owned = Arc::new(lab_owned);

    let mut tasks = tokio::task::JoinSet::new();
    for image in images.clone() {
        let sem = sem.clone();
        let tags_cache = tags_cache.clone();
        let base = base.clone();
        let client = client.clone();
        let upstreams = upstreams.clone();
        let lab_owned = lab_owned.clone();
        tasks.spawn(async move {
            let _permit = sem.acquire_owned().await.expect("semaphore closed");
            warm_one_image(&image, &base, &client, &upstreams, &lab_owned, &tags_cache).await
        });
    }

    report_warm_results(&mut tasks, images.len()).await
}

async fn warm_one_image(
    image: &str,
    base: &str,
    client: &reqwest::Client,
    upstreams: &[String],
    lab_owned: &[String],
    tags_cache: &tokio::sync::Mutex<
        std::collections::HashMap<String, std::collections::HashSet<String>>,
    >,
) -> WarmOutcome {
    let r = parse_image_ref(image);

    if lab_owned.iter().any(|h| h == &r.source_registry) {
        println!(
            "{} {image}... {} (lab-published)",
            style(">>>").cyan(),
            style("skip").dim()
        );
        return WarmOutcome::Skipped;
    }

    if !upstreams.iter().any(|h| h == &r.source_registry) {
        println!(
            "{} {image}... {} (no upstream for '{}')",
            style(">>>").cyan(),
            style("skip").dim(),
            r.source_registry,
        );
        return WarmOutcome::Skipped;
    }

    let cached = {
        let cache = tags_cache.lock().await;
        cache.get(&r.repo).map(|tags| tags.contains(&r.reference))
    };
    let cached = match cached {
        Some(hit) => hit,
        None => {
            let tags_url = format!("{base}/v2/{}/tags/list", r.repo);
            let mut tags = std::collections::HashSet::new();
            if let Ok(resp) = client.get(&tags_url).send().await
                && resp.status().is_success()
                && let Ok(body) = resp.json::<serde_json::Value>().await
                && let Some(arr) = body.get("tags").and_then(|t| t.as_array())
            {
                for v in arr {
                    if let Some(s) = v.as_str() {
                        tags.insert(s.to_owned());
                    }
                }
            }
            let hit = tags.contains(&r.reference);
            tags_cache.lock().await.insert(r.repo.clone(), tags);
            hit
        }
    };

    if cached {
        println!(
            "{} {image}... {}",
            style(">>>").cyan(),
            style("cached").dim()
        );
        return WarmOutcome::Ok;
    }

    let sync_url = format!(
        "{base}/v2/{}/manifests/{}?ns={}",
        r.repo, r.reference, r.source_registry,
    );
    let accept = "application/vnd.oci.image.index.v1+json,\
                  application/vnd.oci.image.manifest.v1+json,\
                  application/vnd.docker.distribution.manifest.list.v2+json,\
                  application/vnd.docker.distribution.manifest.v2+json";

    let resp = client
        .get(&sync_url)
        .header(reqwest::header::ACCEPT, accept)
        .send()
        .await;

    match resp {
        Ok(resp) if resp.status().is_success() => {
            tags_cache.lock().await.remove(&r.repo);
            println!(
                "{} {image}... {}",
                style(">>>").cyan(),
                style("warmed").green()
            );
            WarmOutcome::Ok
        }
        Ok(resp) => {
            println!(
                "{} {image}... {} ({})",
                style(">>>").cyan(),
                style("failed").red(),
                style(format!("HTTP {}", resp.status().as_u16())).dim()
            );
            WarmOutcome::Failed
        }
        Err(e) => {
            println!(
                "{} {image}... {} ({})",
                style(">>>").cyan(),
                style("failed").red(),
                style(format!("{e}")).dim()
            );
            WarmOutcome::Failed
        }
    }
}

async fn report_warm_results(
    tasks: &mut tokio::task::JoinSet<WarmOutcome>,
    total: usize,
) -> Result<()> {
    let mut failed = 0usize;
    let mut skipped = 0usize;
    while let Some(res) = tasks.join_next().await {
        match res {
            Ok(WarmOutcome::Ok) => {}
            Ok(WarmOutcome::Skipped) => skipped += 1,
            Ok(WarmOutcome::Failed) => failed += 1,
            Err(join_err) => {
                failed += 1;
                eprintln!(
                    "{} warm task panicked: {}",
                    style(">>>").red(),
                    style(format!("{join_err}")).dim()
                );
            }
        }
    }

    println!();
    let processed = total - failed - skipped;
    if failed == 0 {
        println!(
            "{} Cache: {processed} ready, {skipped} skipped",
            style(">>>").green(),
        );
    } else {
        println!(
            "{} Cache: {processed} ready, {skipped} skipped, {failed} failed (continuing; \
             affected deployments will retry)",
            style(">>>").yellow(),
        );
    }
    Ok(())
}

pub fn parse_image_ref(image: &str) -> ImageRef {
    let (repo_part, reference) = if let Some(idx) = image.find('@') {
        (&image[..idx], image[idx + 1..].to_string())
    } else if let Some(idx) = image.rfind(':') {
        let after = &image[idx + 1..];
        if after.contains('/') {
            (image, "latest".to_string())
        } else {
            (&image[..idx], after.to_string())
        }
    } else {
        (image, "latest".to_string())
    };

    let (source_registry, repo) = match repo_part.split_once('/') {
        Some((first, rest)) if first.contains('.') || first.contains(':') => {
            (first.to_string(), rest.to_string())
        }
        _ => ("docker.io".to_string(), repo_part.to_string()),
    };

    let repo = if source_registry == "docker.io" && !repo.contains('/') {
        format!("library/{repo}")
    } else {
        repo
    };

    ImageRef {
        source_registry,
        repo,
        reference,
    }
}

pub fn rewrite_image(image: &str, target_registry: &str) -> String {
    let (repo_part, suffix) = if let Some(idx) = image.find('@') {
        (&image[..idx], &image[idx..])
    } else if let Some(idx) = image.rfind(':') {
        let potential_tag = &image[idx + 1..];
        if potential_tag.contains('/') {
            (image, "")
        } else {
            (&image[..idx], &image[idx..])
        }
    } else {
        (image, "")
    };

    let path = if repo_part.contains('/') {
        let first = repo_part.split('/').next().unwrap_or("");
        if first.contains('.') || first.contains(':') {
            &repo_part[first.len() + 1..]
        } else {
            repo_part
        }
    } else {
        repo_part
    };

    format!("{target_registry}/{path}{suffix}")
}

pub fn load_image_list_from_package(lab_package: &str) -> Result<Vec<String>> {
    let images_path = Path::new(lab_package).join("images.txt");
    if !images_path.exists() {
        bail!("No images.txt found in lab package. Rebuild with latest catallaxy.");
    }
    let content = fs::read_to_string(&images_path)
        .with_context(|| format!("reading {}", images_path.display()))?;
    Ok(content
        .lines()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty())
        .collect())
}

pub fn load_image_list(ctx: &CataContext, name: Option<&str>) -> Result<Vec<String>> {
    let lab_name = ctx.resolve_lab_name(name)?;
    let lab_package = nix::build_lab_package(ctx, &lab_name)?;
    let images_path = Path::new(&lab_package).join("images.txt");

    if !images_path.exists() {
        bail!("No images.txt found in lab package. Rebuild with latest catallaxy.");
    }

    let content = fs::read_to_string(&images_path)
        .with_context(|| format!("reading {}", images_path.display()))?;

    let images: Vec<String> = content
        .lines()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty())
        .collect();

    Ok(images)
}

pub struct ImageRef {
    pub source_registry: String,
    pub repo: String,
    pub reference: String,
}

pub enum WarmOutcome {
    Ok,
    Skipped,
    Failed,
}

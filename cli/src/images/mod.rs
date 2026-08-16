use std::path::Path;

pub mod actual;
pub mod reference;
pub use reference::ImageRef;

use anyhow::{Context, Result, bail};
use console::style;

use crate::config::Context as CataContext;
use crate::domain::LabSpec;
use crate::io::nix;

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
        let versions_path = nix::build_out_path(&versions_attr)
            .with_context(|| format!("image '{name}': nix build {versions_attr}"))?;
        let versions_raw = crate::io::fs::read_to_string(&versions_path)
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
        crate::io::crane::push(
            &tarball_path,
            &dest,
            docker_config_dir.as_ref().map(|d| d.path()),
        )
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
    source: &str,
    attr: &str,
    name: &str,
) -> Result<(String, Option<tempfile::TempPath>)> {
    let image_attr = format!("{source}#{attr}");
    println!("{} Building image: {}", style(">>>").cyan(), image_attr);
    let archive_path = nix::build_out_path(&image_attr)
        .with_context(|| format!("image '{name}': nix build {image_attr}"))?;
    println!("   built: {archive_path}");

    let mut tarball_path = archive_path.clone();
    let _decompressed: Option<tempfile::TempPath> = {
        let mut hdr = [0u8; 2];
        let is_gz = {
            use std::io::Read;
            crate::io::fs::open(&archive_path)
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
            if !crate::io::fs::gunzip_to(Path::new(&archive_path), &tmp_path)? {
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
            let _ = crate::io::kubectl::capture(
                cred_ctx,
                &[
                    "-n",
                    cred_namespace,
                    "wait",
                    "--for=create",
                    &format!("secret/{cred_secret}"),
                    "--timeout=2m",
                ],
            );

            let b64 = crate::io::kubectl::capture(
                cred_ctx,
                &[
                    "-n",
                    cred_namespace,
                    "get",
                    "secret",
                    cred_secret,
                    "-o",
                    "jsonpath={.data.\\.dockerconfigjson}",
                ],
            )
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
            crate::io::fs::write(tmp.path().join("config.json"), &json_bytes)
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

    let concurrency = crate::io::fs::env_var("CATA_WARM_CONCURRENCY")
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
    let r = match plan_warm(image, upstreams, lab_owned) {
        WarmRoute::LabPublished => {
            println!(
                "{} {image}... {} (lab-published)",
                style(">>>").cyan(),
                style("skip").dim()
            );
            return WarmOutcome::Skipped;
        }
        WarmRoute::NoUpstream(registry) => {
            println!(
                "{} {image}... {} (no upstream for '{registry}')",
                style(">>>").cyan(),
                style("skip").dim(),
            );
            return WarmOutcome::Skipped;
        }
        WarmRoute::Fetch(r) => r,
    };

    // A tag list never contains a digest, so a digest-pinned reference would
    // report uncached every run and re-sync every run. Ask about the tag it
    // also carries; a mirror holding the tag holds the content.
    let cache_key = r.tag.clone().unwrap_or_else(|| r.reference());

    let cached = {
        let cache = tags_cache.lock().await;
        cache
            .get(&r.api_repository())
            .map(|tags| tags.contains(&cache_key))
    };
    let cached = match cached {
        Some(hit) => hit,
        None => {
            let mut tags = std::collections::HashSet::new();
            if let Ok(resp) = client.get(tags_url(base, &r.api_repository())).send().await
                && resp.status().is_success()
                && let Ok(body) = resp.json::<serde_json::Value>().await
            {
                tags = tags_from_body(&body);
            }
            let hit = tags.contains(&cache_key);
            tags_cache.lock().await.insert(r.api_repository(), tags);
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

    let sync_url = sync_url(base, &r);
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
            tags_cache.lock().await.remove(&r.api_repository());
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

pub fn load_image_list_from_package(lab_package: &str) -> Result<Vec<String>> {
    let images_path = Path::new(lab_package).join("images.txt");
    if !images_path.exists() {
        bail!("No images.txt found in lab package. Rebuild with latest catallaxy.");
    }
    let content = crate::io::fs::read_to_string(&images_path)
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

    let content = crate::io::fs::read_to_string(&images_path)
        .with_context(|| format!("reading {}", images_path.display()))?;

    let images: Vec<String> = content
        .lines()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty())
        .collect();

    Ok(images)
}

pub enum WarmOutcome {
    Ok,
    Skipped,
    Failed,
}

#[derive(Debug, PartialEq, Eq)]
pub enum WarmRoute {
    LabPublished,
    NoUpstream(String),
    Fetch(ImageRef),
}

pub fn plan_warm(image: &str, upstreams: &[String], lab_owned: &[String]) -> WarmRoute {
    let r = ImageRef::parse(image);
    if lab_owned.iter().any(|h| h == &r.registry) {
        WarmRoute::LabPublished
    } else if !upstreams.iter().any(|h| h == &r.registry) {
        WarmRoute::NoUpstream(r.registry)
    } else {
        WarmRoute::Fetch(r)
    }
}

pub fn tags_from_body(body: &serde_json::Value) -> std::collections::HashSet<String> {
    body.get("tags")
        .and_then(|t| t.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str())
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default()
}

pub fn tags_url(base: &str, repo: &str) -> String {
    format!("{base}/v2/{repo}/tags/list")
}

pub fn sync_url(base: &str, r: &ImageRef) -> String {
    format!(
        "{base}/v2/{}/manifests/{}?ns={}",
        r.api_repository(),
        r.reference(),
        r.registry,
    )
}

#[cfg(test)]
mod warm_tests {
    use super::*;

    fn hosts(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn an_image_from_a_lab_registry_is_never_pulled_through_the_mirror() {
        assert_eq!(
            plan_warm(
                "registry.lab.local/team/app:v1",
                &hosts(&["docker.io"]),
                &hosts(&["registry.lab.local"]),
            ),
            WarmRoute::LabPublished
        );
    }

    #[test]
    fn lab_ownership_wins_over_a_registry_that_is_also_an_upstream() {
        assert_eq!(
            plan_warm(
                "registry.lab.local/team/app:v1",
                &hosts(&["registry.lab.local"]),
                &hosts(&["registry.lab.local"]),
            ),
            WarmRoute::LabPublished
        );
    }

    #[test]
    fn an_image_with_no_configured_upstream_names_the_registry_it_wanted() {
        assert_eq!(
            plan_warm("quay.io/team/app:v1", &hosts(&["docker.io"]), &[]),
            WarmRoute::NoUpstream("quay.io".to_string())
        );
    }

    #[test]
    fn an_upstream_image_is_routed_to_a_fetch_carrying_its_parsed_reference() {
        let WarmRoute::Fetch(r) =
            plan_warm("docker.io/library/nginx:1.25", &hosts(&["docker.io"]), &[])
        else {
            panic!("expected a fetch");
        };
        assert_eq!(r.registry, "docker.io");
        assert_eq!(r.reference(), "1.25");
    }

    #[test]
    fn a_tags_list_becomes_a_set_of_tag_names() {
        let body = serde_json::json!({ "name": "library/nginx", "tags": ["1.25", "latest"] });
        let tags = tags_from_body(&body);
        assert!(tags.contains("1.25"));
        assert!(tags.contains("latest"));
        assert_eq!(tags.len(), 2);
    }

    #[test]
    fn a_repository_with_no_tags_yields_an_empty_set_rather_than_failing() {
        assert!(tags_from_body(&serde_json::json!({ "tags": null })).is_empty());
        assert!(tags_from_body(&serde_json::json!({})).is_empty());
    }

    #[test]
    fn the_sync_url_asks_the_mirror_for_the_upstream_namespace() {
        let r = ImageRef::parse("docker.io/library/nginx:1.25");
        assert_eq!(
            sync_url("http://localhost:5000", &r),
            "http://localhost:5000/v2/library/nginx/manifests/1.25?ns=docker.io"
        );
        assert_eq!(
            tags_url("http://localhost:5000", &r.api_repository()),
            "http://localhost:5000/v2/library/nginx/tags/list"
        );
    }
}

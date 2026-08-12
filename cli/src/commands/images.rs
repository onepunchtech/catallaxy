use std::fs;
use std::path::Path;

use anyhow::{Context, Result, bail};
use clap::Subcommand;
use console::style;

use crate::config::Context as CataContext;
use crate::io::nix;

const IMAGES_NAME_HELP: &str = "Lab to act on. Defaults to the flake fragment";

#[derive(Subcommand)]
pub enum ImagesCommands {
    #[command(about = "List every image the lab references")]
    List {
        #[arg(long, value_name = "LAB", help = IMAGES_NAME_HELP)]
        name: Option<String>,
    },

    #[command(about = "Copy the lab's images into a registry")]
    Mirror {
        #[arg(long, value_name = "LAB", help = IMAGES_NAME_HELP)]
        name: Option<String>,

        #[arg(long, value_name = "REGISTRY", help = "Registry to copy images into")]
        registry: String,

        #[arg(long, help = "Print what would be copied without copying it")]
        dry_run: bool,
    },

    #[command(about = "Pull the lab's images into the local registry cache")]
    Prefetch {
        #[arg(long, value_name = "LAB", help = IMAGES_NAME_HELP)]
        name: Option<String>,

        #[arg(
            long,
            default_value = "localhost:5050",
            value_name = "REGISTRY",
            help = "Registry cache to pull into"
        )]
        registry: String,

        #[arg(long, help = "Print what would be pulled without pulling it")]
        dry_run: bool,
    },
}

pub async fn run(ctx: &CataContext, command: ImagesCommands) -> Result<()> {
    match command {
        ImagesCommands::List { name } => list(ctx, name.as_deref()).await,
        ImagesCommands::Mirror {
            name,
            registry,
            dry_run,
        } => mirror(ctx, name.as_deref(), &registry, dry_run).await,
        ImagesCommands::Prefetch {
            name,
            registry,
            dry_run,
        } => prefetch(ctx, name.as_deref(), &registry, dry_run).await,
    }
}

fn load_image_list_from_package(lab_package: &str) -> Result<Vec<String>> {
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

fn load_image_list(ctx: &CataContext, name: Option<&str>) -> Result<Vec<String>> {
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

async fn list(ctx: &CataContext, name: Option<&str>) -> Result<()> {
    let images = load_image_list(ctx, name)?;

    println!(
        "{} Lab images ({} total):",
        style("catallaxy").cyan().bold(),
        images.len()
    );
    println!();

    for image in &images {
        println!("  {image}");
    }

    Ok(())
}

async fn mirror(
    ctx: &CataContext,
    name: Option<&str>,
    target_registry: &str,
    dry_run: bool,
) -> Result<()> {
    if !dry_run {
        crate::io::process::check_tool("crane")?;
    }

    let images = load_image_list(ctx, name)?;

    println!(
        "{} Mirroring {} images to {}",
        style("catallaxy").cyan().bold(),
        images.len(),
        style(target_registry).bold(),
    );
    println!();

    for image in &images {
        let target = rewrite_image(image, target_registry);

        if dry_run {
            println!("  {} → {}", style(image).dim(), style(&target).bold());
            continue;
        }

        println!(
            "{} {} → {}",
            style(">>>").cyan(),
            image,
            style(&target).bold()
        );

        let mut cmd = std::process::Command::new("crane");
        crate::io::trust::apply(&mut cmd);
        let status = cmd
            .args(["copy", image, &target])
            .status()
            .with_context(|| format!("Failed to copy {image}"))?;

        if !status.success() {
            println!("{} Failed to copy {}", style("!!!").red(), image);
        }
    }

    if dry_run {
        println!();
        println!(
            "{} Dry run: {} images would be mirrored",
            style("Note:").yellow(),
            images.len()
        );
    } else {
        println!();
        println!("{} All images mirrored", style(">>>").green());
    }

    Ok(())
}

async fn prefetch(
    ctx: &CataContext,
    name: Option<&str>,
    target_registry: &str,
    dry_run: bool,
) -> Result<()> {
    if dry_run {
        let images = load_image_list(ctx, name)?;
        println!(
            "{} Warming {} images via {} (dry run)",
            style("catallaxy").cyan().bold(),
            images.len(),
            style(target_registry).bold(),
        );
        println!();
        for image in &images {
            let parsed = parse_image_ref(image);
            println!(
                "  {} → {}/v2/{}/manifests/{}?ns={}",
                style(image).dim(),
                target_registry,
                parsed.repo,
                parsed.reference,
                parsed.source_registry,
            );
        }
        println!();
        println!(
            "{} Dry run: {} images would be warmed",
            style("Note:").yellow(),
            images.len()
        );
        return Ok(());
    }
    warm_to_target(ctx, name, target_registry).await
}

#[derive(Debug)]
struct ImageRef {
    source_registry: String,
    repo: String,
    reference: String,
}

fn parse_image_ref(image: &str) -> ImageRef {
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

pub async fn warm_to_target(
    ctx: &CataContext,
    name: Option<&str>,
    target_registry: &str,
) -> Result<()> {
    warm_to_target_with(ctx, name, target_registry, None, None).await
}

pub async fn warm_to_target_with(
    ctx: &CataContext,
    name: Option<&str>,
    target_registry: &str,
    lab_config: Option<&serde_json::Value>,
    lab_pkg: Option<&str>,
) -> Result<()> {
    let images = if let Some(pkg) = lab_pkg {
        load_image_list_from_package(pkg)?
    } else {
        load_image_list(ctx, name)?
    };

    let lab = if let Some(config) = lab_config {
        config.clone()
    } else {
        crate::io::nix::get_lab_config(ctx, &ctx.resolve_lab_name(name)?)?
    };
    let upstreams: Vec<String> = lab
        .pointer("/registryUpstreams")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default();
    let lab_owned: Vec<String> = lab
        .pointer("/labOwnedRegistries")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default();

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

enum WarmOutcome {
    Ok,
    Skipped,
    Failed,
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

fn rewrite_image(image: &str, target_registry: &str) -> String {
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

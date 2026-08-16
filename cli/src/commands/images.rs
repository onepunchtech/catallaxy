use anyhow::{Context, Result, bail};
use clap::Subcommand;
use console::style;

use crate::config::Context as CataContext;

const IMAGES_NAME_HELP: &str = "Lab to act on. Defaults to the flake fragment";

#[derive(Subcommand)]
pub enum ImagesCommands {
    #[command(about = "List every image the lab references")]
    List {
        #[arg(long, value_name = "LAB", help = IMAGES_NAME_HELP)]
        name: Option<String>,
    },

    #[command(
        about = "List every image the lab's clusters are actually running",
        long_about = "Reads the images back out of a running lab.\n\n\
                      `list` says what catallaxy rendered. It cannot say what \
                      arrived: an operator creates workloads catallaxy never \
                      wrote, so a CNPG Postgres pod or a StatefulSet an operator \
                      built are invisible to anything reading manifests. This \
                      asks the clusters instead, which is what to hand to a \
                      mirror for an air-gapped or edge deployment.\n\n\
                      It reports what has already run, so it says nothing about \
                      a workload that has not started yet."
    )]
    Actual {
        #[arg(long, value_name = "LAB", help = IMAGES_NAME_HELP)]
        name: Option<String>,

        #[arg(
            long,
            value_name = "CLUSTER",
            help = "Only this cluster. Defaults to every cluster in the lab"
        )]
        cluster: Option<String>,

        #[arg(
            long,
            help = "Only the images the lab never rendered, which is what an operator created"
        )]
        undeclared: bool,
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

    #[command(about = "Resolve every image the lab references to a digest and write a lockfile")]
    Lock {
        #[arg(long, value_name = "LAB", help = IMAGES_NAME_HELP)]
        name: Option<String>,

        #[arg(
            long,
            default_value = "images.lock.json",
            value_name = "PATH",
            help = "Lockfile to write, relative to the flake"
        )]
        out: String,
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
        ImagesCommands::Actual {
            name,
            cluster,
            undeclared,
        } => actual(ctx, name.as_deref(), cluster.as_deref(), undeclared).await,
        ImagesCommands::Lock { name, out } => lock(ctx, name.as_deref(), &out).await,
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

/// The reference a lockfile is keyed on: whatever a manifest carries, with
/// any digest stripped.
///
/// Stripping is what makes re-locking a lab that already renders digests give
/// back the same keys, so the file refreshes rather than growing a second
/// entry per image.
fn lock_key(image: &str) -> &str {
    match image.split_once('@') {
        Some((before, _)) => before,
        None => image,
    }
}

async fn lock(ctx: &CataContext, name: Option<&str>, out: &str) -> Result<()> {
    let Some(dir) = ctx.flake_ref.local_dir() else {
        bail!(
            "a lockfile has to be written beside the flake, and '{}' is not a local one.\n\n                 Run this against a checkout, then commit the file it writes.",
            ctx.flake_ref.uri
        );
    };

    crate::io::process::check_tool("crane").context(
        "resolving digests needs crane, which is not on PATH. The dev shell provides it",
    )?;

    let images = crate::images::load_image_list(ctx, name)?;
    let mut keys: Vec<&str> = images.iter().map(|i| lock_key(i)).collect();
    keys.sort_unstable();
    keys.dedup();

    println!(
        "{} Resolving {} image(s) to digests",
        style("catallaxy").cyan().bold(),
        keys.len()
    );

    let mut resolved = std::collections::BTreeMap::new();
    let mut failed = Vec::new();
    for key in keys {
        match crate::io::crane::digest(key) {
            Ok(d) => {
                println!("  {key} -> {d}");
                resolved.insert(key.to_string(), d);
            }
            Err(e) => {
                println!("  {} {key}: {e}", style("skipped").yellow());
                failed.push(key.to_string());
            }
        }
    }

    let path = dir.join(out);
    let body = serde_json::to_string_pretty(&serde_json::json!({
        "version": 1,
        "images": resolved,
    }))?;
    crate::io::fs::write_atomic(&path, format!("{body}\n").as_bytes())?;

    println!();
    println!("{} Wrote {}", style(">>>").green(), path.display());

    // A reference nothing could resolve is left out rather than guessed at,
    // and saying so matters: with `requireDigest` on, the lint will name it.
    if !failed.is_empty() {
        println!(
            "{} {} image(s) are not in the lockfile: {}",
            style("Warning:").yellow(),
            failed.len(),
            failed.join(", ")
        );
    }

    Ok(())
}

async fn list(ctx: &CataContext, name: Option<&str>) -> Result<()> {
    let images = crate::images::load_image_list(ctx, name)?;

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

async fn actual(
    ctx: &CataContext,
    name: Option<&str>,
    cluster: Option<&str>,
    only_undeclared: bool,
) -> Result<()> {
    crate::io::process::check_tool("kubectl")?;

    let lab = crate::io::nix::get_lab_spec(ctx, &ctx.resolve_lab_name(name)?)?;

    let clusters: Vec<(&String, &String)> = match cluster {
        Some(wanted) => vec![
            lab.runtime_contexts
                .get_key_value(wanted)
                .with_context(|| {
                    format!(
                        "cluster '{wanted}' is not in this lab (available: {})",
                        lab.runtime_contexts
                            .keys()
                            .cloned()
                            .collect::<Vec<_>>()
                            .join(", ")
                    )
                })?,
        ],
        None => lab.runtime_contexts.iter().collect(),
    };

    if clusters.is_empty() {
        bail!(
            "this lab has no clusters with a kubectl context, so there is nothing running to read"
        );
    }

    let mut images = std::collections::BTreeSet::new();
    let mut unreachable = Vec::new();

    for (cluster_name, context) in &clusters {
        match crate::io::kubectl::capture(context, &["get", "pods", "-A", "-o", "json"]) {
            Ok(out) => match serde_json::from_str(&out) {
                Ok(payload) => {
                    images.extend(crate::images::actual::images_in_pods(&payload));
                }
                Err(e) => unreachable.push(format!("{cluster_name}: {e}")),
            },
            Err(e) => unreachable.push(format!("{cluster_name}: {e}")),
        }
    }

    // A cluster that is down makes the answer incomplete, and an incomplete
    // list handed to a mirror is a deploy that fails somewhere else later.
    // Naming the gap beats printing a shorter list that looks whole.
    if !unreachable.is_empty() {
        for line in &unreachable {
            eprintln!(
                "{} could not read {}",
                style("warning").yellow().bold(),
                line
            );
        }
        if unreachable.len() == clusters.len() {
            bail!("no cluster in this lab could be read, so there is nothing to report");
        }
    }

    let shown: Vec<&str> = if only_undeclared {
        let rendered = crate::images::load_image_list(ctx, name)?;
        crate::images::actual::undeclared(&images, &rendered)
    } else {
        images.iter().map(String::as_str).collect()
    };

    println!(
        "{} {} image(s) running across {} cluster(s):",
        style("catallaxy").cyan().bold(),
        shown.len(),
        clusters.len() - unreachable.len(),
    );
    println!();

    for image in &shown {
        println!("  {image}");
    }

    if only_undeclared && shown.is_empty() {
        println!("  (everything running is something the lab rendered)");
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

    let images = crate::images::load_image_list(ctx, name)?;

    println!(
        "{} Mirroring {} images to {}",
        style("catallaxy").cyan().bold(),
        images.len(),
        style(target_registry).bold(),
    );
    println!();

    let mut failed: Vec<&String> = Vec::new();

    for image in &images {
        let target = crate::images::ImageRef::parse(image).with_registry(target_registry);

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

        let status = crate::io::crane::copy(image, &target)
            .with_context(|| format!("Failed to copy {image}"))?;

        if !status.success() {
            println!("{} Failed to copy {}", style("!!!").red(), image);
            failed.push(image);
        }
    }

    if dry_run {
        println!();
        println!(
            "{} Dry run: {} images would be mirrored",
            style("Note:").yellow(),
            images.len()
        );
        return Ok(());
    }

    println!();
    if failed.is_empty() {
        println!(
            "{} All {} images mirrored",
            style(">>>").green(),
            images.len()
        );
        return Ok(());
    }

    bail!(
        "mirrored {}/{} images. These failed and will not be in '{}', so pods \
         referencing them will ImagePullBackOff:\n  {}",
        images.len() - failed.len(),
        images.len(),
        target_registry,
        failed
            .iter()
            .map(|i| i.as_str())
            .collect::<Vec<_>>()
            .join("\n  "),
    )
}

async fn prefetch(
    ctx: &CataContext,
    name: Option<&str>,
    target_registry: &str,
    dry_run: bool,
) -> Result<()> {
    if dry_run {
        let images = crate::images::load_image_list(ctx, name)?;
        println!(
            "{} Warming {} images via {} (dry run)",
            style("catallaxy").cyan().bold(),
            images.len(),
            style(target_registry).bold(),
        );
        println!();
        for image in &images {
            let parsed = crate::images::ImageRef::parse(image);
            println!(
                "  {} → {}/v2/{}/manifests/{}?ns={}",
                style(image).dim(),
                target_registry,
                parsed.api_repository(),
                parsed.reference(),
                parsed.registry,
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

pub async fn warm_to_target(
    ctx: &CataContext,
    name: Option<&str>,
    target_registry: &str,
) -> Result<()> {
    crate::images::warm_to_target_with(ctx, name, target_registry, None, None).await
}

#[cfg(test)]
mod tests {
    use super::*;

    // Re-locking a lab that already renders digests has to give back the same
    // keys, or the file grows a second entry per image every run.
    #[test]
    fn a_digest_is_stripped_back_to_the_reference_that_produced_it() {
        assert_eq!(lock_key("nginx:1.27@sha256:abc"), "nginx:1.27");
        assert_eq!(lock_key("nginx:1.27"), "nginx:1.27");
        assert_eq!(
            lock_key("ghcr.io/o/r@sha256:abc"),
            "ghcr.io/o/r",
            "a registry with a port would be the interesting case; this one has none"
        );
    }

    // A port colon is not a tag colon, and stripping on `@` never has to tell
    // them apart.
    #[test]
    fn a_registry_port_survives_stripping() {
        assert_eq!(
            lock_key("localhost:5050/team/app:1.2@sha256:abc"),
            "localhost:5050/team/app:1.2"
        );
    }
}

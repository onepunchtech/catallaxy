//! Image management commands
//!
//! Mirror lab images to a registry or prefetch into a local cache.

use std::fs;
use std::path::Path;

use anyhow::{Context, Result, bail};
use clap::Subcommand;
use console::style;

use crate::config::Context as CataContext;
use crate::nix;

#[derive(Subcommand)]
pub enum ImagesCommands {
    /// List all container images used by a lab
    List {
        /// Lab name (defaults to flake fragment)
        #[arg(long)]
        name: Option<String>,
    },

    /// Mirror lab images to a target registry using crane
    Mirror {
        /// Lab name (defaults to flake fragment)
        #[arg(long)]
        name: Option<String>,

        /// Target registry (e.g., ghcr.io/my-org, registry.example.com)
        #[arg(long)]
        registry: String,

        /// Dry run — show what would be copied
        #[arg(long)]
        dry_run: bool,
    },

    /// Prefetch lab images into a local registry (e.g., Zot pull-through cache)
    Prefetch {
        /// Lab name (defaults to flake fragment)
        #[arg(long)]
        name: Option<String>,

        /// Target registry (default: localhost:5050 for lab Zot)
        #[arg(long, default_value = "localhost:5050")]
        registry: String,

        /// Dry run — show what would be prefetched
        #[arg(long)]
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

/// Load the image list from the lab package's images.txt
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
        crate::tools::check_tool("crane")?;
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

        let status = std::process::Command::new("crane")
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
            "{} Dry run — {} images would be mirrored",
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
    if !dry_run {
        crate::tools::check_tool("crane")?;
    }

    let images = load_image_list(ctx, name)?;

    println!(
        "{} Prefetching {} images into {}",
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

        print!("{} {image}... ", style(">>>").cyan());

        let status = std::process::Command::new("crane")
            .args(["copy", image, &target])
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .status();

        match status {
            Ok(s) if s.success() => println!("{}", style("ok").green()),
            _ => println!("{}", style("failed").red()),
        }
    }

    if dry_run {
        println!();
        println!(
            "{} Dry run — {} images would be prefetched",
            style("Note:").yellow(),
            images.len()
        );
    } else {
        println!();
        println!("{} Prefetch complete", style(">>>").green());
    }

    Ok(())
}

/// Rewrite an image reference to a target registry.
/// docker.io/grafana/grafana:11.0.0 → registry.example.com/grafana/grafana:11.0.0
fn rewrite_image(image: &str, target_registry: &str) -> String {
    // Split off digest/tag
    let (repo_part, suffix) = if let Some(idx) = image.find('@') {
        (&image[..idx], &image[idx..])
    } else if let Some(idx) = image.rfind(':') {
        // Avoid splitting on port numbers
        let potential_tag = &image[idx + 1..];
        if potential_tag.contains('/') {
            (image, "")
        } else {
            (&image[..idx], &image[idx..])
        }
    } else {
        (image, "")
    };

    // Remove the source registry prefix
    let path = if repo_part.contains('/') {
        let first = repo_part.split('/').next().unwrap_or("");
        if first.contains('.') || first.contains(':') {
            // Has explicit registry — strip it
            &repo_part[first.len() + 1..]
        } else {
            // docker.io implicit — keep as-is (e.g., "grafana/grafana")
            repo_part
        }
    } else {
        // Single name like "nginx" → "library/nginx"
        repo_part
    };

    format!("{target_registry}/{path}{suffix}")
}

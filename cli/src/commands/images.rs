use anyhow::{Context, Result};
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

    for image in &images {
        let target = crate::images::rewrite_image(image, target_registry);

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
        cmd.args(["copy", image, &target]);
        let status = crate::io::process::run_status(&mut cmd)
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
        let images = crate::images::load_image_list(ctx, name)?;
        println!(
            "{} Warming {} images via {} (dry run)",
            style("catallaxy").cyan().bold(),
            images.len(),
            style(target_registry).bold(),
        );
        println!();
        for image in &images {
            let parsed = crate::images::parse_image_ref(image);
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

pub async fn warm_to_target(
    ctx: &CataContext,
    name: Option<&str>,
    target_registry: &str,
) -> Result<()> {
    crate::images::warm_to_target_with(ctx, name, target_registry, None, None).await
}

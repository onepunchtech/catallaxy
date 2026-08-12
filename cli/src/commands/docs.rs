use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use clap::Subcommand;

use crate::docs::{cli, llms, options, summary};

#[derive(Subcommand)]
pub enum DocsCommands {
    #[command(about = "Render the option reference pages and splice them into SUMMARY.md")]
    Render {
        #[arg(help = "Option metadata from the module system")]
        options_json: PathBuf,
        #[arg(help = "Book summary to splice the generated nav into")]
        summary_md: PathBuf,
        #[arg(help = "Where to write the generated pages")]
        out_dir: PathBuf,
    },

    #[command(about = "Generate llms.txt from the built book")]
    Llms {
        #[arg(help = "Book source directory")]
        src: PathBuf,
        #[arg(help = "Base URL the generated links are rooted at")]
        base_url: String,
        #[arg(help = "Where to write llms.txt")]
        out_dir: PathBuf,
    },
}

pub fn run(command: DocsCommands, root: clap::Command) -> Result<()> {
    match command {
        DocsCommands::Render {
            options_json,
            summary_md,
            out_dir,
        } => render(&options_json, &summary_md, &out_dir, &root),
        DocsCommands::Llms {
            src,
            base_url,
            out_dir,
        } => write_llms(&src, &base_url, &out_dir),
    }
}

fn render(
    options_json: &Path,
    summary_md: &Path,
    out_dir: &Path,
    root: &clap::Command,
) -> Result<()> {
    let raw = fs::read_to_string(options_json)
        .with_context(|| format!("reading {}", options_json.display()))?;
    let all: BTreeMap<String, options::OptionDoc> = serde_json::from_str(&raw)
        .with_context(|| format!("parsing {}", options_json.display()))?;

    let rendered = match options::render_all(all) {
        Ok(r) => r,
        Err(options::RenderError::Unrouted(unrouted)) => {
            eprintln!("{} option(s) matched no page route:", unrouted.len());
            for name in &unrouted {
                eprintln!("  {name}");
            }
            bail!(
                "add a route in cli/src/docs/options.rs rather than letting these \
                 vanish from the reference"
            );
        }
        Err(options::RenderError::AnchorCollision(message)) => bail!(
            "{message}\n\nTwo options slugify to the same anchor, so a deep link \
             would land on whichever renders first. Disambiguate in `anchor` in \
             cli/src/docs/options.rs."
        ),
    };

    let mut pages = rendered.pages;
    pages.push(options::Page {
        path: "cli/commands.md".into(),
        body: cli::render(root),
    });

    let mut paths = Vec::new();
    for page in &pages {
        let target = out_dir.join(&page.path);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
        }
        fs::write(&target, &page.body).with_context(|| format!("writing {}", target.display()))?;
        paths.push(page.path.clone());
    }

    paths.sort();

    let mut undescribed = rendered.undescribed.join("\n");
    if !undescribed.is_empty() {
        undescribed.push('\n');
    }
    fs::write(out_dir.join("undescribed.txt"), undescribed).context("writing undescribed.txt")?;

    let summary_text = fs::read_to_string(summary_md)
        .with_context(|| format!("reading {}", summary_md.display()))?;
    fs::write(
        out_dir.join("SUMMARY.md"),
        summary::splice_nav(&summary_text, &paths),
    )
    .context("writing SUMMARY.md")?;

    println!(
        "Generated docs for {} options across {} pages",
        rendered.option_count,
        paths.len()
    );
    Ok(())
}

fn write_llms(src: &Path, base_url: &str, out_dir: &Path) -> Result<()> {
    let summary_path = src.join("SUMMARY.md");
    let summary_text = fs::read_to_string(&summary_path)
        .with_context(|| format!("reading {}", summary_path.display()))?;
    let entries = summary::parse(&summary_text);

    let mut omitted = 0;
    let mut pages = Vec::new();
    for entry in &entries {
        if entry.path.starts_with("reference/options/") || entry.path == "reference/cli/commands.md"
        {
            omitted += 1;
            continue;
        }
        let page_path = src.join(&entry.path);
        let Ok(body) = fs::read_to_string(&page_path) else {
            continue;
        };
        pages.push(llms::Page { entry, body });
    }

    let out = llms::render(&pages, omitted, base_url);
    fs::create_dir_all(out_dir).with_context(|| format!("creating {}", out_dir.display()))?;
    fs::write(out_dir.join("llms.txt"), &out.index).context("writing llms.txt")?;
    fs::write(out_dir.join("llms-full.txt"), &out.full).context("writing llms-full.txt")?;

    println!(
        "llms.txt: {} pages indexed, {} option pages omitted",
        out.indexed, out.omitted
    );
    Ok(())
}

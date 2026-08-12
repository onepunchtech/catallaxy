use anyhow::Result;
use console::style;
use serde_json::Value;

use crate::plan::StepContext;

pub fn run(sctx: &StepContext<'_>, src_cluster: &str, images: &[Value]) -> Result<()> {
    if images.is_empty() {
        println!(
            "{} No images to publish for '{}', skipping",
            style(">>>").yellow(),
            src_cluster,
        );
        return Ok(());
    }

    if sctx.dry_run {
        for img in images {
            let name = img["name"].as_str().unwrap_or("?");
            let dest = img["destination"].as_str().unwrap_or("?");
            println!(
                "{} [dry-run] would build '{}' and push to docker://{}",
                style(">>>").yellow(),
                name,
                dest,
            );
        }
        return Ok(());
    }

    for img in images {
        crate::commands::lab::orchestrate::publish_one_image(sctx.lab, src_cluster, img)?;
    }
    Ok(())
}

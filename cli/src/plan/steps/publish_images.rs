use anyhow::Result;
use console::style;

use crate::domain::plan::PublishImagesParams;
use crate::plan::StepContext;

pub fn run(sctx: &StepContext<'_>, p: &PublishImagesParams) -> Result<()> {
    let PublishImagesParams {
        source_cluster: src_cluster,
        images,
    } = p;

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
        crate::images::publish_one(sctx.lab, img)?;
    }
    Ok(())
}

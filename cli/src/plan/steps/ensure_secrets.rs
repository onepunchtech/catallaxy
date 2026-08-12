use anyhow::{Result, bail};
use console::style;

use crate::plan::StepContext;

pub fn run(sctx: &StepContext<'_>, stores: &[String]) -> Result<()> {
    if sctx.secrets_cache.is_some() {
        println!(
            "{} Stores already decrypted in preflight, skipping",
            style(">>>").green()
        );
        return Ok(());
    }

    let missing: Vec<&str> = stores
        .iter()
        .filter(|store_name| {
            let enc_path =
                crate::commands::secrets::store_file_path(sctx.ctx, sctx.lab_name, store_name);
            !enc_path.exists()
        })
        .map(|s| s.as_str())
        .collect();

    if !missing.is_empty() {
        bail!(
            "Missing secret stores: {}\nRun these commands first:\n  cata secrets generate\n  cata secrets edit {}",
            missing.join(", "),
            missing.first().copied().unwrap_or(""),
        );
    }

    for store_name in stores {
        println!("{} Store '{}' exists", style(">>>").green(), store_name);
    }
    Ok(())
}

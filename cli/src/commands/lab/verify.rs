use anyhow::{Context, Result, bail};
use console::style;

use crate::config::Context as CataContext;
use crate::domain::LabSpec;
use crate::verify::{self, CHECK_NAMES, Severity, VerifyConfig, VerifyContext};

pub async fn run(
    ctx: &CataContext,
    name: Option<String>,
    only: Option<String>,
    json: bool,
) -> Result<()> {
    if let Some(check) = &only
        && !CHECK_NAMES.contains(&check.as_str())
    {
        bail!(
            "--check='{check}' is not a check. Valid checks:\n  {}",
            CHECK_NAMES.join("\n  ")
        );
    }

    let lab_name = ctx.resolve_lab_name(name.as_deref())?;
    let raw = crate::io::nix::get_lab_config(ctx, &lab_name)?;
    let config: VerifyConfig = serde_json::from_value(raw["verify"].clone())
        .context("parsing the lab's verify configuration")?;
    let lab: LabSpec =
        serde_json::from_value(raw).context("parsing the lab configuration into a LabSpec")?;

    crate::io::trust::activate(&lab_name).ok();

    let package = match crate::io::nix::build_lab_package(ctx, &lab_name) {
        Ok(p) => Some(std::path::PathBuf::from(p)),
        Err(e) => {
            eprintln!(
                "{} could not build the lab package, so the checks its floes declare are skipped: {e}",
                style("warning:").yellow(),
            );
            None
        }
    };

    let vctx = VerifyContext {
        lab_name: &lab_name,
        lab: &lab,
        config: &config,
        package: package.as_deref(),
    };

    if !json {
        println!(
            "{} Verifying lab '{lab_name}'",
            style("catallaxy").cyan().bold(),
        );
        println!("  clusters: {}", lab.cluster_names.join(", "));
        println!();
    }

    let diagnostics = verify::run(&vctx, only.as_deref()).await;
    let errors = diagnostics
        .iter()
        .filter(|d| d.severity == Severity::Error)
        .count();

    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(&verify::as_json(&diagnostics))?
        );
    } else {
        report(&diagnostics, errors);
    }

    if errors > 0 {
        return Err(crate::domain::ExitWith(1).into());
    }
    Ok(())
}

fn report(diagnostics: &[crate::verify::Diagnostic], errors: usize) {
    if diagnostics.is_empty() {
        println!(
            "  {} the lab answers on every surface it declares",
            style("✓").green().bold()
        );
        return;
    }

    for d in diagnostics {
        let severity = match d.severity {
            Severity::Error => style("ERROR").red().bold(),
            Severity::Warning => style("WARN").yellow(),
        };
        println!(
            "  {} [{}] {} {}: {}",
            severity, d.check, d.cluster, d.resource, d.message,
        );
    }

    println!();
    let warnings = diagnostics.len() - errors;
    if errors > 0 {
        println!(
            "  {} {errors} error(s), {warnings} warning(s)",
            style("✗").red().bold(),
        );
    } else {
        println!("  {} {warnings} warning(s)", style("⚠").yellow());
    }
}

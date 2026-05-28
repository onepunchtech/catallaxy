//! Lab manifest linting
//!
//! Runs property checks against rendered Kubernetes manifests to catch
//! issues before deployment: schema validity, identity uniqueness,
//! prefix completeness, selector matching, and reference integrity.

pub mod checks;
pub mod manifest;

use std::collections::HashMap;
use std::path::Path;

use anyhow::{Context, Result};
use console::style;
use serde::Deserialize;

use checks::{Diagnostic, Severity};

/// Lab metadata read from out.package/metadata.json
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LabMetadata {
    pub name: String,
    #[serde(default)]
    pub prefix: String,
    pub cluster_names: Vec<String>,
    #[serde(default)]
    pub lab_namespaces: HashMap<String, Vec<String>>,
}

/// Available lint checks
const ALL_CHECKS: &[&str] = &["schema", "identity", "prefix", "selector", "reference", "crd-schema", "missing-crd"];

/// Run all lint checks against a built lab package.
///
/// Returns `true` if all checks pass (no errors), `false` if any errors found.
pub fn run_lint(package_path: &Path, skip: &[String]) -> Result<bool> {
    let metadata_path = package_path.join("metadata.json");
    let metadata_content = std::fs::read_to_string(&metadata_path)
        .with_context(|| format!("reading {}", metadata_path.display()))?;
    let metadata: LabMetadata = serde_json::from_str(&metadata_content)
        .with_context(|| format!("parsing {}", metadata_path.display()))?;

    println!(
        "{} Linting lab '{}'",
        style("catallaxy").cyan().bold(),
        metadata.name,
    );

    if !metadata.prefix.is_empty() {
        println!("  prefix: {}", style(&metadata.prefix).yellow());
    }
    println!("  clusters: {}", metadata.cluster_names.join(", "));
    println!();

    let active_checks: Vec<&str> = ALL_CHECKS
        .iter()
        .filter(|c| !skip.contains(&c.to_string()))
        .copied()
        .collect();

    let mut all_diagnostics: Vec<Diagnostic> = Vec::new();

    for cluster_name in &metadata.cluster_names {
        let manifest_dir = package_path.join("manifests").join(cluster_name);

        if !manifest_dir.exists() {
            println!(
                "  {} {} — manifest directory not found, skipping",
                style("⚠").yellow(),
                cluster_name,
            );
            continue;
        }

        let resources = manifest::load_manifests(&manifest_dir)
            .with_context(|| format!("loading manifests for cluster '{}'", cluster_name))?;

        println!(
            "  {} {} ({} resources)",
            style("→").dim(),
            cluster_name,
            resources.len(),
        );

        let mut cluster_diags = Vec::new();

        for check_name in &active_checks {
            let diags = match *check_name {
                "schema" => checks::check_schema(&resources, cluster_name),
                "identity" => checks::check_identity(&resources, cluster_name),
                "prefix" => {
                    let lab_ns = metadata
                        .lab_namespaces
                        .get(cluster_name)
                        .map(|v| v.as_slice())
                        .unwrap_or(&[]);
                    checks::check_prefix(&resources, cluster_name, &metadata.prefix, lab_ns)
                }
                "selector" => checks::check_selectors(&resources, cluster_name),
                "reference" => checks::check_references(&resources, cluster_name),
                "crd-schema" => checks::check_crd_schema(&resources, cluster_name),
                "missing-crd" => checks::check_missing_crds(&resources, cluster_name),
                _ => Vec::new(),
            };
            cluster_diags.extend(diags);
        }

        all_diagnostics.extend(cluster_diags);
    }

    println!();
    print_report(&all_diagnostics);

    let has_errors = all_diagnostics
        .iter()
        .any(|d| d.severity == Severity::Error);

    Ok(!has_errors)
}

fn print_report(diagnostics: &[Diagnostic]) {
    if diagnostics.is_empty() {
        println!("  {} All checks passed", style("✓").green().bold(),);
        return;
    }

    let errors = diagnostics
        .iter()
        .filter(|d| d.severity == Severity::Error)
        .count();
    let warnings = diagnostics
        .iter()
        .filter(|d| d.severity == Severity::Warning)
        .count();

    // Group by cluster then by check
    let mut by_cluster: HashMap<&str, Vec<&Diagnostic>> = HashMap::new();
    for d in diagnostics {
        by_cluster.entry(&d.cluster).or_default().push(d);
    }

    for (cluster, diags) in &by_cluster {
        println!("  {}:", style(*cluster).bold());
        for d in diags {
            let severity_str = match d.severity {
                Severity::Error => style("ERROR").red().bold(),
                Severity::Warning => style("WARN").yellow(),
            };
            let file = d.file.file_name().and_then(|n| n.to_str()).unwrap_or("?");
            println!(
                "    {} [{}] {} — {} ({})",
                severity_str, d.check, d.resource, d.message, file,
            );
        }
    }

    println!();
    if errors > 0 {
        println!(
            "  {} {} error(s), {} warning(s)",
            style("✗").red().bold(),
            errors,
            warnings,
        );
    } else {
        println!("  {} {} warning(s)", style("⚠").yellow(), warnings,);
    }
}

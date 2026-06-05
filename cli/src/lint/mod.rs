//! Lab manifest linting
//!
//! Runs property checks against rendered Kubernetes manifests to catch
//! issues before deployment: schema validity, identity uniqueness,
//! prefix completeness, selector matching, and reference integrity.

pub mod checks;
pub mod manifest;

use std::collections::{HashMap, HashSet};
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
    #[serde(default)]
    pub clusters: HashMap<String, ClusterMetadata>,
    #[serde(default)]
    pub images: ImagePolicy,
    #[serde(default)]
    pub lint: LintConfig,
}

#[derive(Debug, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct LintConfig {
    #[serde(default)]
    pub checks: HashMap<String, CustomCheck>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CustomCheck {
    pub description: String,
    pub severity: String,
}

#[derive(Debug, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ImagePolicy {
    #[serde(default)]
    pub require_digest: bool,
    #[serde(default)]
    pub allowed_registries: Vec<String>,
}

#[derive(Debug, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ClusterMetadata {
    #[serde(default)]
    pub projections: HashMap<String, ProjectionMetadata>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
#[allow(dead_code)]
pub struct ProjectionMetadata {
    pub namespace: String,
    pub phase: String,
    #[serde(default)]
    pub source: String,
}

/// Available lint checks
const ALL_CHECKS: &[&str] = &[
    "schema",
    "identity",
    "prefix",
    "selector",
    "reference",
    "projection-ref",
    "image-pin",
    "crd-schema",
    "missing-crd",
];

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

        // Collect projection names for this cluster (secrets injected at runtime, not in manifests)
        let cluster_meta = metadata.clusters.get(cluster_name);
        let projection_names: HashSet<String> = cluster_meta
            .map(|c| c.projections.keys().cloned().collect())
            .unwrap_or_default();

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
                "reference" => {
                    checks::check_references(&resources, cluster_name, &projection_names)
                }
                "projection-ref" => {
                    if let Some(cm) = cluster_meta {
                        checks::check_projection_refs(&resources, cluster_name, cm)
                    } else {
                        Vec::new()
                    }
                }
                "image-pin" => checks::check_image_pins(&resources, cluster_name, &metadata.images),
                "crd-schema" => checks::check_crd_schema(&resources, cluster_name),
                "missing-crd" => checks::check_missing_crds(&resources, cluster_name),
                _ => Vec::new(),
            };
            cluster_diags.extend(diags);
        }

        // Run custom lint checks (Nix-defined shell scripts)
        let lint_dir = package_path.join("lint");
        if lint_dir.exists() && !skip.contains(&"custom".to_string()) {
            let manifest_dir = package_path.join("manifests").join(cluster_name);
            if let Ok(entries) = std::fs::read_dir(&lint_dir) {
                for entry in entries.filter_map(|e| e.ok()) {
                    let check_name = entry.file_name().to_string_lossy().to_string();
                    let check_meta = metadata.lint.checks.get(&check_name);
                    let severity = check_meta
                        .map(|c| {
                            if c.severity == "error" {
                                checks::Severity::Error
                            } else {
                                checks::Severity::Warning
                            }
                        })
                        .unwrap_or(checks::Severity::Warning);
                    let description = check_meta
                        .map(|c| c.description.as_str())
                        .unwrap_or(&check_name);

                    // Walk manifest YAML files for this cluster
                    if let Ok(yaml_files) = walkdir::WalkDir::new(&manifest_dir)
                        .into_iter()
                        .filter_map(|e| e.ok())
                        .filter(|e| {
                            e.path()
                                .extension()
                                .map_or(false, |ext| ext == "yaml" || ext == "yml")
                        })
                        .map(|e| e.into_path())
                        .collect::<Vec<_>>()
                        .into_iter()
                        .map(Ok::<_, std::io::Error>)
                        .collect::<Result<Vec<_>, _>>()
                    {
                        for yaml_file in &yaml_files {
                            let output = std::process::Command::new(entry.path())
                                .env("FILE", yaml_file)
                                .env("CLUSTER", cluster_name)
                                .output();

                            if let Ok(o) = output {
                                if !o.status.success() {
                                    let msg = String::from_utf8_lossy(&o.stdout);
                                    let message = if msg.trim().is_empty() {
                                        description.to_string()
                                    } else {
                                        format!("{}: {}", description, msg.trim())
                                    };
                                    cluster_diags.push(checks::Diagnostic {
                                        severity,
                                        check: "custom",
                                        cluster: cluster_name.to_string(),
                                        file: yaml_file.clone(),
                                        resource: check_name.clone(),
                                        message,
                                    });
                                }
                            }
                        }
                    }
                }
            }
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

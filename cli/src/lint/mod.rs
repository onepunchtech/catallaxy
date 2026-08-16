pub mod manifest;
pub mod rules;

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use console::style;
use serde::Deserialize;

pub use crate::domain::diagnostic::{Diagnostic, Severity};
use crate::domain::plan::PlannedStep;

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
    pub assertions: Vec<AssertionMetadata>,
    #[serde(default)]
    pub warnings: Vec<String>,
    #[serde(default)]
    pub deployment_plan: Vec<PlannedStep>,
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
    #[serde(default = "default_scope")]
    pub scope: String,
    #[serde(default = "default_format")]
    pub format: String,
}

fn default_scope() -> String {
    "per-file".to_string()
}

fn default_format() -> String {
    "exit-code".to_string()
}

#[derive(Debug, Deserialize)]
struct CustomDiagnostic {
    #[serde(default)]
    severity: Option<String>,
    #[serde(default)]
    resource: Option<String>,
    message: String,
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
    /// A floe's check applies only where that floe is enabled, so the set is
    /// per cluster rather than one flat lab-wide list.
    #[serde(default)]
    pub lint: LintConfig,
    #[serde(default)]
    pub assertions: Vec<AssertionMetadata>,
    #[serde(default)]
    pub warnings: Vec<String>,
    #[serde(default)]
    pub runtime_materialised: Vec<String>,
    #[serde(default)]
    pub network_policies: NetworkPolicyMetadata,
}

/// What the floes on a cluster said they serve.
///
/// Only the serving half: that is where a human writes a port number, so it
/// is the half worth checking against the Services the cluster renders.
#[derive(Debug, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct NetworkPolicyMetadata {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub floes: HashMap<String, FloeNetworkMetadata>,
}

#[derive(Debug, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct FloeNetworkMetadata {
    #[serde(default)]
    pub namespaces: Vec<String>,
    #[serde(default)]
    pub serves: HashMap<String, ServedPort>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServedPort {
    pub port: serde_json::Value,
    #[serde(default = "default_protocol")]
    pub protocol: String,
}

fn default_protocol() -> String {
    "TCP".to_string()
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectionMetadata {
    pub namespace: String,
    #[serde(default)]
    pub source: String,
}

#[derive(Debug, Deserialize)]
pub struct AssertionMetadata {
    pub assertion: bool,
    pub message: String,
}

pub fn run_lint(package_path: &Path, skip: &[String]) -> Result<bool> {
    let metadata_path = package_path.join("metadata.json");
    let metadata_content = crate::io::fs::read_to_string(&metadata_path)
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

    let registry = rules::cluster_rules();
    let lab_registry = rules::lab_rules();
    let mut all_diagnostics: Vec<Diagnostic> = Vec::new();

    if !skip.iter().any(|s| s == "assertions") {
        all_diagnostics.extend(rules::assertions::check_lab(&metadata));
    }

    let mut resources_by_cluster: HashMap<String, Vec<manifest::K8sResource>> = HashMap::new();

    for cluster_name in &metadata.cluster_names {
        let manifest_dir = package_path.join("manifests").join(cluster_name);

        if !manifest_dir.exists() {
            println!(
                "  {} {}: manifest directory not found, skipping",
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

        let cluster_meta = metadata.clusters.get(cluster_name);
        let mut projection_names: HashSet<String> = cluster_meta
            .map(|c| c.projections.keys().cloned().collect())
            .unwrap_or_default();

        // An ExternalSecret produces a Secret that no manifest declares, the
        // same way a projection does. Without this the checks report the
        // Secret as unproduced and a probe waiting on it as waiting on an
        // ExternalSecret, which is true and unhelpful.
        projection_names.extend(external_secret_targets(&resources));

        let lab_ns = metadata
            .lab_namespaces
            .get(cluster_name)
            .map(|v| v.as_slice())
            .unwrap_or(&[]);

        let wave_meta = crate::io::ssa::read_wave_meta(&manifest_dir);

        let ctx = rules::CheckContext {
            resources: &resources,
            cluster: cluster_name,
            wave_meta: wave_meta.as_ref(),
            prefix: &metadata.prefix,
            lab_namespaces: lab_ns,
            projection_names: &projection_names,
            cluster_meta,
            images: &metadata.images,
        };

        let mut cluster_diags: Vec<Diagnostic> = registry
            .iter()
            .filter(|r| !skip.iter().any(|s| s == r.name()))
            .flat_map(|r| r.check(&ctx))
            .collect();

        let lint_dir = package_path.join("lint").join(cluster_name);
        if lint_dir.exists() && !skip.contains(&"custom".to_string()) {
            let manifest_dir = package_path.join("manifests").join(cluster_name);
            let empty = LintConfig::default();
            let checks = cluster_meta.map_or(&empty.checks, |c| &c.lint.checks);
            cluster_diags.extend(run_custom_checks(
                &lint_dir,
                &manifest_dir,
                cluster_name,
                checks,
            ));
        }

        all_diagnostics.extend(cluster_diags);
        resources_by_cluster.insert(cluster_name.clone(), resources);
    }

    let lab_ctx = rules::LabCheckContext {
        metadata: &metadata,
        resources_by_cluster: &resources_by_cluster,
        deployment_plan: &metadata.deployment_plan,
    };
    for rule in &lab_registry {
        if !skip.iter().any(|s| s == rule.name()) {
            all_diagnostics.extend(rule.check(&lab_ctx));
        }
    }

    println!();
    print_report(&all_diagnostics);

    let has_errors = all_diagnostics
        .iter()
        .any(|d| d.severity == Severity::Error);

    Ok(!has_errors)
}

fn run_custom_checks(
    lint_dir: &Path,
    manifest_dir: &Path,
    cluster_name: &str,
    checks: &HashMap<String, CustomCheck>,
) -> Vec<Diagnostic> {
    let mut diags = Vec::new();
    let entries = match crate::io::fs::read_dir(lint_dir) {
        Ok(e) => e,
        Err(_) => return diags,
    };
    for entry in entries.filter_map(|e| e.ok()) {
        let check_name = entry.file_name().to_string_lossy().to_string();
        let meta = checks.get(&check_name);
        let severity = meta
            .map(|c| parse_severity(&c.severity))
            .unwrap_or(Severity::Warning);
        let description = meta.map(|c| c.description.as_str()).unwrap_or(&check_name);
        let scope = meta.map(|c| c.scope.as_str()).unwrap_or("per-file");
        let format = meta.map(|c| c.format.as_str()).unwrap_or("exit-code");
        let script = entry.path();

        match scope {
            "per-cluster" => {
                let out = crate::io::check_script::run(
                    &script,
                    &[
                        ("CLUSTER", cluster_name.as_ref()),
                        ("MANIFEST_DIR", manifest_dir.as_ref()),
                    ],
                );
                diags.extend(interpret_output(
                    out,
                    format,
                    severity,
                    &check_name,
                    description,
                    cluster_name,
                    manifest_dir.to_path_buf(),
                ));
            }
            _ => {
                let walker = walkdir::WalkDir::new(manifest_dir).into_iter();
                for e in walker.filter_map(|e| e.ok()) {
                    if !e
                        .path()
                        .extension()
                        .is_some_and(|ext| ext == "yaml" || ext == "yml")
                    {
                        continue;
                    }
                    let yaml_file = e.into_path();
                    let out = crate::io::check_script::run(
                        &script,
                        &[
                            ("FILE", yaml_file.as_ref()),
                            ("CLUSTER", cluster_name.as_ref()),
                        ],
                    );
                    diags.extend(interpret_output(
                        out,
                        format,
                        severity,
                        &check_name,
                        description,
                        cluster_name,
                        yaml_file,
                    ));
                }
            }
        }
    }
    diags
}

fn parse_severity(s: &str) -> Severity {
    if s == "error" {
        Severity::Error
    } else {
        Severity::Warning
    }
}

fn interpret_output(
    output: std::io::Result<std::process::Output>,
    format: &str,
    default_severity: Severity,
    check_name: &str,
    description: &str,
    cluster_name: &str,
    file: PathBuf,
) -> Vec<Diagnostic> {
    let o = match output {
        Ok(o) => o,
        Err(e) => {
            return vec![Diagnostic {
                severity: Severity::Error,
                check: "custom",
                cluster: cluster_name.to_string(),
                file,
                resource: check_name.to_string(),
                message: format!("{description}: check failed to execute: {e}"),
            }];
        }
    };
    match format {
        "json" => {
            let stdout = String::from_utf8_lossy(&o.stdout);
            let parsed: Result<Vec<CustomDiagnostic>, _> = serde_json::from_str(stdout.trim());
            match parsed {
                Ok(list) => list
                    .into_iter()
                    .map(|d| Diagnostic {
                        severity: d
                            .severity
                            .as_deref()
                            .map(parse_severity)
                            .unwrap_or(default_severity),
                        check: "custom",
                        cluster: cluster_name.to_string(),
                        file: file.clone(),
                        resource: d.resource.unwrap_or_else(|| check_name.to_string()),
                        message: d.message,
                    })
                    .collect(),
                Err(e) => vec![Diagnostic {
                    severity: Severity::Error,
                    check: "custom",
                    cluster: cluster_name.to_string(),
                    file,
                    resource: check_name.to_string(),
                    message: format!(
                        "{}: check emitted invalid JSON ({}): {}",
                        description,
                        e,
                        stdout.trim(),
                    ),
                }],
            }
        }
        _ => {
            if o.status.success() {
                return Vec::new();
            }
            let msg = String::from_utf8_lossy(&o.stdout);
            let message = if msg.trim().is_empty() {
                description.to_string()
            } else {
                format!("{}: {}", description, msg.trim())
            };
            vec![Diagnostic {
                severity: default_severity,
                check: "custom",
                cluster: cluster_name.to_string(),
                file,
                resource: check_name.to_string(),
                message,
            }]
        }
    }
}

fn print_report(diagnostics: &[Diagnostic]) {
    print!("{}", render_report(diagnostics));
}

/// Secret names an ExternalSecret will create. `spec.target.name` when set,
/// otherwise the ExternalSecret's own name, which is what external-secrets
/// falls back to.
fn external_secret_targets(resources: &[manifest::K8sResource]) -> HashSet<String> {
    resources
        .iter()
        .filter(|r| r.kind == "ExternalSecret")
        .map(|r| {
            r.raw
                .get("spec")
                .and_then(|s| s.get("target"))
                .and_then(|t| t.get("name"))
                .and_then(|n| n.as_str())
                .unwrap_or(&r.name)
                .to_string()
        })
        .collect()
}

fn render_diagnostic(d: &Diagnostic) -> String {
    let severity = match d.severity {
        Severity::Error => style("ERROR").red().bold(),
        Severity::Warning => style("WARN").yellow(),
    };
    let file = d.file.file_name().and_then(|n| n.to_str()).unwrap_or("?");
    format!(
        "    {} [{}] {}: {} ({})\n",
        severity, d.check, d.resource, d.message, file,
    )
}

fn render_summary(errors: usize, warnings: usize) -> String {
    if errors > 0 {
        format!(
            "  {} {errors} error(s), {warnings} warning(s)\n",
            style("\u{2717}").red().bold(),
        )
    } else {
        format!("  {} {warnings} warning(s)\n", style("\u{26a0}").yellow())
    }
}

pub fn render_report(diagnostics: &[Diagnostic]) -> String {
    if diagnostics.is_empty() {
        return format!("  {} All checks passed\n", style("\u{2713}").green().bold());
    }

    // Ordered, so two runs over the same lab print the same report.
    let mut by_cluster: std::collections::BTreeMap<&str, Vec<&Diagnostic>> =
        std::collections::BTreeMap::new();
    for d in diagnostics {
        by_cluster.entry(&d.cluster).or_default().push(d);
    }

    let mut out = String::new();
    for (cluster, diags) in &by_cluster {
        out.push_str(&format!("  {}:\n", style(*cluster).bold()));
        for d in diags {
            out.push_str(&render_diagnostic(d));
        }
    }

    out.push('\n');
    out.push_str(&render_summary(
        diagnostics
            .iter()
            .filter(|d| d.severity == Severity::Error)
            .count(),
        diagnostics
            .iter()
            .filter(|d| d.severity == Severity::Warning)
            .count(),
    ));
    out
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    fn write_script(dir: &Path, name: &str, body: &str) -> PathBuf {
        let path = dir.join(name);
        crate::io::fs::write(&path, format!("#!/bin/sh\n{}\n", body)).unwrap();
        let mut perms = crate::io::fs::metadata(&path).unwrap().permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&path, perms).unwrap();
        path
    }

    fn tmpdir(subpath: &str) -> PathBuf {
        let base = crate::io::fs::temp_root();
        let dir =
            PathBuf::from(base).join(format!("cata-lint-{}-{}", subpath, std::process::id(),));
        let _ = crate::io::fs::remove_dir_all(&dir);
        crate::io::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn check(scope: &str, format: &str) -> CustomCheck {
        CustomCheck {
            description: "test check".into(),
            severity: "warning".into(),
            scope: scope.into(),
            format: format.into(),
        }
    }

    #[test]
    fn per_cluster_scope_invokes_once_per_cluster() {
        let root = tmpdir("per-cluster");
        let lint_dir = root.join("lint");
        let manifest_dir = root.join("manifests");
        crate::io::fs::create_dir_all(&lint_dir).unwrap();
        crate::io::fs::create_dir_all(&manifest_dir).unwrap();
        crate::io::fs::write(manifest_dir.join("a.yaml"), "kind: X").unwrap();
        crate::io::fs::write(manifest_dir.join("b.yaml"), "kind: Y").unwrap();

        write_script(&lint_dir, "count", "echo boom; exit 1");
        let mut checks = HashMap::new();
        checks.insert("count".to_string(), check("per-cluster", "exit-code"));

        let diags = run_custom_checks(&lint_dir, &manifest_dir, "c1", &checks);
        assert_eq!(
            diags.len(),
            1,
            "per-cluster should invoke once, not per file"
        );
        assert!(diags[0].message.contains("boom"));
    }

    #[test]
    fn per_file_scope_invokes_once_per_yaml() {
        let root = tmpdir("per-file");
        let lint_dir = root.join("lint");
        let manifest_dir = root.join("manifests");
        crate::io::fs::create_dir_all(&lint_dir).unwrap();
        crate::io::fs::create_dir_all(&manifest_dir).unwrap();
        crate::io::fs::write(manifest_dir.join("a.yaml"), "kind: X").unwrap();
        crate::io::fs::write(manifest_dir.join("b.yaml"), "kind: Y").unwrap();
        write_script(&lint_dir, "always-fail", "echo x; exit 1");

        let mut checks = HashMap::new();
        checks.insert("always-fail".to_string(), check("per-file", "exit-code"));

        let diags = run_custom_checks(&lint_dir, &manifest_dir, "c1", &checks);
        assert_eq!(diags.len(), 2, "per-file should invoke once per YAML");
    }

    #[test]
    fn json_format_lifts_structured_diagnostics() {
        let root = tmpdir("json");
        let lint_dir = root.join("lint");
        let manifest_dir = root.join("manifests");
        crate::io::fs::create_dir_all(&lint_dir).unwrap();
        crate::io::fs::create_dir_all(&manifest_dir).unwrap();
        write_script(
            &lint_dir,
            "structured",
            r#"cat <<EOF
[
  {"severity": "error",   "resource": "Deploy/api",  "message": "missing probe"},
  {"severity": "warning", "resource": "Deploy/api",  "message": "no requests"}
]
EOF"#,
        );

        let mut checks = HashMap::new();
        checks.insert("structured".to_string(), check("per-cluster", "json"));

        let diags = run_custom_checks(&lint_dir, &manifest_dir, "c1", &checks);
        assert_eq!(diags.len(), 2);
        assert_eq!(diags[0].severity, Severity::Error);
        assert_eq!(diags[0].resource, "Deploy/api");
        assert_eq!(diags[0].message, "missing probe");
        assert_eq!(diags[1].severity, Severity::Warning);
    }

    #[test]
    fn json_format_empty_array_is_silent() {
        let root = tmpdir("json-empty");
        let lint_dir = root.join("lint");
        let manifest_dir = root.join("manifests");
        crate::io::fs::create_dir_all(&lint_dir).unwrap();
        crate::io::fs::create_dir_all(&manifest_dir).unwrap();
        write_script(&lint_dir, "quiet", "echo '[]'");

        let mut checks = HashMap::new();
        checks.insert("quiet".to_string(), check("per-cluster", "json"));

        assert!(run_custom_checks(&lint_dir, &manifest_dir, "c1", &checks).is_empty());
    }

    #[test]
    fn json_format_invalid_stdout_reports_error() {
        let root = tmpdir("json-invalid");
        let lint_dir = root.join("lint");
        let manifest_dir = root.join("manifests");
        crate::io::fs::create_dir_all(&lint_dir).unwrap();
        crate::io::fs::create_dir_all(&manifest_dir).unwrap();
        write_script(&lint_dir, "broken", "echo 'not json at all'");

        let mut checks = HashMap::new();
        checks.insert("broken".to_string(), check("per-cluster", "json"));

        let diags = run_custom_checks(&lint_dir, &manifest_dir, "c1", &checks);
        assert_eq!(diags.len(), 1);
        assert_eq!(diags[0].severity, Severity::Error);
        assert!(diags[0].message.contains("invalid JSON"));
    }

    #[test]
    fn unrunnable_check_is_reported_not_swallowed() {
        let root = tmpdir("unrunnable");
        let lint_dir = root.join("lint");
        let manifest_dir = root.join("manifests");
        crate::io::fs::create_dir_all(&lint_dir).unwrap();
        crate::io::fs::create_dir_all(&manifest_dir).unwrap();
        let script = lint_dir.join("broken");
        crate::io::fs::write(&script, "#!/bin/sh\necho '[]'\n").unwrap();
        let mut perms = crate::io::fs::metadata(&script).unwrap().permissions();
        perms.set_mode(0o644);
        fs::set_permissions(&script, perms).unwrap();

        let mut checks = HashMap::new();
        checks.insert("broken".to_string(), check("per-cluster", "json"));

        let diags = run_custom_checks(&lint_dir, &manifest_dir, "c1", &checks);
        assert_eq!(diags.len(), 1);
        assert_eq!(diags[0].severity, Severity::Error);
        assert!(
            diags[0].message.contains("failed to execute"),
            "unexpected message: {}",
            diags[0].message
        );
    }

    #[test]
    fn missing_metadata_falls_back_to_per_file_exit_code() {
        let root = tmpdir("legacy");
        let lint_dir = root.join("lint");
        let manifest_dir = root.join("manifests");
        crate::io::fs::create_dir_all(&lint_dir).unwrap();
        crate::io::fs::create_dir_all(&manifest_dir).unwrap();
        crate::io::fs::write(manifest_dir.join("a.yaml"), "kind: X").unwrap();
        write_script(&lint_dir, "legacy-check", "echo hi; exit 1");

        let diags = run_custom_checks(&lint_dir, &manifest_dir, "c1", &HashMap::new());
        assert_eq!(diags.len(), 1);
        assert_eq!(diags[0].severity, Severity::Warning);
    }

    fn diagnostic(severity: Severity, cluster: &str, message: &str) -> Diagnostic {
        Diagnostic {
            severity,
            check: "ready-probe",
            cluster: cluster.to_string(),
            file: PathBuf::from("/tmp/manifests/app.yaml"),
            resource: "bundle/app".to_string(),
            message: message.to_string(),
        }
    }

    #[test]
    fn a_clean_lint_reports_one_line_and_no_summary() {
        assert_eq!(
            console::strip_ansi_codes(&render_report(&[])),
            "  \u{2713} All checks passed\n"
        );
    }

    #[test]
    fn a_diagnostic_carries_its_check_resource_message_and_file() {
        let report = render_report(&[diagnostic(Severity::Error, "dev", "probe never resolves")]);
        let report = console::strip_ansi_codes(&report);
        assert_eq!(
            report,
            "  dev:\n    ERROR [ready-probe] bundle/app: probe never resolves (app.yaml)\n\n  \u{2717} 1 error(s), 0 warning(s)\n"
        );
    }

    #[test]
    fn warnings_alone_do_not_report_an_error_count() {
        let report = render_report(&[diagnostic(Severity::Warning, "dev", "no probe")]);
        let report = console::strip_ansi_codes(&report);
        assert!(report.ends_with("  \u{26a0} 1 warning(s)\n"), "{report}");
        assert!(!report.contains("error(s)"), "{report}");
    }

    #[test]
    fn one_error_among_warnings_switches_the_summary_to_the_error_form() {
        let report = render_report(&[
            diagnostic(Severity::Warning, "dev", "a"),
            diagnostic(Severity::Error, "dev", "b"),
            diagnostic(Severity::Warning, "dev", "c"),
        ]);
        let report = console::strip_ansi_codes(&report);
        assert!(
            report.ends_with("  \u{2717} 1 error(s), 2 warning(s)\n"),
            "{report}"
        );
    }

    #[test]
    fn clusters_are_reported_in_a_stable_order() {
        let diags: Vec<Diagnostic> = ["zulu", "alpha", "mike"]
            .iter()
            .map(|c| diagnostic(Severity::Error, c, "boom"))
            .collect();

        let report = console::strip_ansi_codes(&render_report(&diags)).to_string();
        let order: Vec<&str> = ["alpha", "mike", "zulu"]
            .iter()
            .filter(|c| report.contains(&format!("  {c}:")))
            .copied()
            .collect();

        assert_eq!(order, ["alpha", "mike", "zulu"]);
        let positions: Vec<usize> = order
            .iter()
            .map(|c| report.find(&format!("  {c}:")).unwrap())
            .collect();
        assert!(
            positions.windows(2).all(|w| w[0] < w[1]),
            "clusters out of order: {report}"
        );
    }
}

use std::path::Path;
use std::process::Command;

use serde::Deserialize;

use crate::verify::{Diagnostic, Severity, VerifyContext, diag};

const CHECK: &str = "chainsaw";

#[derive(Debug, Deserialize)]
struct Report {
    #[serde(default)]
    tests: Vec<TestReport>,
}

#[derive(Debug, Deserialize)]
struct TestReport {
    #[serde(default)]
    steps: Vec<StepReport>,
}

#[derive(Debug, Deserialize)]
struct StepReport {
    #[serde(default)]
    name: String,
    #[serde(default)]
    operations: Vec<OperationReport>,
}

#[derive(Debug, Deserialize)]
struct OperationReport {
    #[serde(default)]
    failure: Option<Failure>,
}

#[derive(Debug, Deserialize)]
struct Failure {
    #[serde(default)]
    error: String,
}

/// Runs the Chainsaw tests rendered into the lab package, one per cluster.
///
/// The assertions come from the floes a lab enables rather than from the lab
/// itself, so a lab inherits them by enabling a component. What a failure
/// says is Chainsaw's message, which names the offending resource.
pub fn run(ctx: &VerifyContext<'_>, package: &Path) -> Vec<Diagnostic> {
    let mut diags = Vec::new();

    for cluster in &ctx.lab.cluster_names {
        let test_dir = package.join("verify").join(cluster);
        if !test_dir.join("chainsaw-test.yaml").exists() {
            continue;
        }

        let Some(context) = ctx.context_for(cluster) else {
            continue;
        };

        let report_dir = match tempfile::tempdir() {
            Ok(d) => d,
            Err(e) => {
                diags.push(diag(
                    Severity::Error,
                    CHECK,
                    cluster,
                    "report",
                    format!("could not make a directory for the report: {e}"),
                ));
                continue;
            }
        };

        let kubeconfig = std::env::var("KUBECONFIG").unwrap_or_else(|_| {
            format!(
                "{}/.kube/config",
                std::env::var("HOME").unwrap_or_else(|_| "/root".into())
            )
        });

        let output = Command::new("chainsaw")
            .args([
                "test",
                "--test-dir",
                &test_dir.display().to_string(),
                "--cluster",
                &format!("{cluster}={kubeconfig}:{context}"),
                "--report-format",
                "JSON",
                "--report-path",
                &report_dir.path().display().to_string(),
                "--report-name",
                "report",
            ])
            .output();

        let output = match output {
            Ok(o) => o,
            Err(e) => {
                diags.push(diag(
                    Severity::Error,
                    CHECK,
                    cluster,
                    "chainsaw",
                    format!("could not run chainsaw: {e}"),
                ));
                continue;
            }
        };

        let report_path = report_dir.path().join("report.json");
        let parsed: Option<Report> = std::fs::read(&report_path)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok());

        let Some(report) = parsed else {
            if !output.status.success() {
                diags.push(diag(
                    Severity::Error,
                    CHECK,
                    cluster,
                    "chainsaw",
                    format!(
                        "chainsaw failed and wrote no report: {}",
                        String::from_utf8_lossy(&output.stderr).trim()
                    ),
                ));
            }
            continue;
        };

        if report.tests.is_empty() {
            diags.push(diag(
                Severity::Error,
                CHECK,
                cluster,
                "chainsaw",
                format!(
                    "{} exists but chainsaw ran no tests from it. It reports that as \
                     success, so every assertion the floes declared would have been \
                     silently skipped.",
                    test_dir.display()
                ),
            ));
            continue;
        }

        for test in &report.tests {
            for step in &test.steps {
                for op in &step.operations {
                    if let Some(failure) = &op.failure {
                        diags.push(diag(
                            Severity::Error,
                            CHECK,
                            cluster,
                            &step.name,
                            failure.error.clone(),
                        ));
                    }
                }
            }
        }
    }

    diags
}

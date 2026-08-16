use std::path::Path;

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

        let output = match run_chainsaw(&test_dir, cluster, context, report_dir.path()) {
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

        diags.extend(report_diagnostics(
            cluster,
            &test_dir,
            report_dir.path(),
            &output,
        ));
    }

    diags
}

fn run_chainsaw(
    test_dir: &Path,
    cluster: &str,
    context: &str,
    report_dir: &Path,
) -> std::io::Result<std::process::Output> {
    let kubeconfig = crate::io::fs::kubeconfig_path();

    crate::io::chainsaw::test(test_dir, cluster, &kubeconfig, context, report_dir)
}

fn report_diagnostics(
    cluster: &str,
    test_dir: &Path,
    report_dir: &Path,
    output: &std::process::Output,
) -> Vec<Diagnostic> {
    let mut diags = Vec::new();
    let parsed: Option<Report> = crate::io::fs::read(report_dir.join("report.json"))
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
        return diags;
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
        return diags;
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

    diags
}

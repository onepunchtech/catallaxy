use std::path::Path;
use std::process::Command;

/// # Errors
///
/// Only if `chainsaw` cannot be spawned. A failing test is a non-zero status
/// in the returned `Output`, and the JSON report is on disk either way.
pub fn test(
    test_dir: &Path,
    cluster: &str,
    kubeconfig: &str,
    context: &str,
    report_dir: &Path,
) -> std::io::Result<std::process::Output> {
    let mut cmd = Command::new("chainsaw");
    // Through the seam, so it gets the lab's KUBECONFIG. Chainsaw consults
    // the default kubeconfig even when handed an explicit one per cluster,
    // and a stale `current-context` there fails the run with a context this
    // lab never named.
    crate::io::process::prepare_env(&mut cmd);
    cmd.args([
        "test",
        "--test-dir",
        &test_dir.display().to_string(),
        "--cluster",
        &format!("{cluster}={kubeconfig}:{context}"),
        "--report-format",
        "JSON",
        "--report-path",
        &report_dir.display().to_string(),
        "--report-name",
        "report",
    ])
    .output()
}

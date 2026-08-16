use std::path::Path;
use std::process::Command;

pub fn test(
    test_dir: &Path,
    cluster: &str,
    kubeconfig: &str,
    context: &str,
    report_dir: &Path,
) -> std::io::Result<std::process::Output> {
    Command::new("chainsaw")
        .args([
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

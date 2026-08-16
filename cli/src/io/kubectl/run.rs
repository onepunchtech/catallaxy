use std::path::Path;
use std::process::{Command, Stdio};

use anyhow::Result;

use crate::io::process::run_capture;

/// A kubectl invocation, with the lab's trust settings already on it.
///
/// Every kubectl the CLI spawns goes through here. It used to be spawned two
/// ways, some through `io::process` and some bare, and the difference was
/// whether the subprocess got the lab's merged CA bundle. The bundle is a
/// union of the system roots and the lab CA, so handing it over is never a
/// narrowing, and which callers had it was historical rather than decided.
pub fn command() -> Command {
    let mut cmd = Command::new("kubectl");
    crate::io::process::prepare_env(&mut cmd);
    cmd
}

pub fn parse_timeout(timeout: &str) -> Option<std::time::Duration> {
    let t = timeout.trim();
    let (digits, multiplier) = match t.strip_suffix(['h', 'm', 's']) {
        Some(rest) => match t.as_bytes().last()? {
            b'h' => (rest, 3600),
            b'm' => (rest, 60),
            _ => (rest, 1),
        },
        None => (t, 1),
    };
    let n: u64 = digits.parse().ok()?;
    Some(std::time::Duration::from_secs(n * multiplier))
}

pub fn create_namespace_if_missing(context: &str, namespace: &str) {
    let mut cmd = command();
    cmd.args(["--context", context, "create", "namespace", namespace]);
    let _ = run_capture(&mut cmd);
}

pub fn render_tls_secret(
    context: &str,
    name: &str,
    namespace: &str,
    cert: &Path,
    key: &Path,
) -> Result<String> {
    let mut cmd = command();
    cmd.args([
        "--context",
        context,
        "create",
        "secret",
        "tls",
        name,
        "-n",
        namespace,
        "--dry-run=client",
        "-o",
        "yaml",
        "--cert",
    ])
    .arg(cert)
    .args(["--key"])
    .arg(key);
    run_capture(&mut cmd)
}

pub fn apply_stdin(context: &str, manifest: &[u8]) -> Result<()> {
    let mut cmd = command();
    cmd.args(["--context", context, "apply", "-f", "-"]);
    crate::io::process::run_with_stdin(&mut cmd, manifest)?;
    Ok(())
}

pub fn output(context: &str, args: &[&str]) -> std::io::Result<std::process::Output> {
    command().args(["--context", context]).args(args).output()
}

pub fn status(context: &str, args: &[&str]) -> std::io::Result<std::process::ExitStatus> {
    command().args(["--context", context]).args(args).status()
}

pub fn quiet_status(context: &str, args: &[&str]) -> std::io::Result<std::process::ExitStatus> {
    command()
        .args(["--context", context])
        .args(args)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
}

pub fn apply_stdin_succeeded(context: &str, manifest: &[u8]) -> std::io::Result<bool> {
    use std::io::Write;

    let mut child = command()
        .args(["--context", context, "apply", "-f", "-"])
        .stdin(Stdio::piped())
        .spawn()?;
    child
        .stdin
        .as_mut()
        .expect("stdin was piped in the command builder above")
        .write_all(manifest)?;
    Ok(child.wait()?.success())
}

pub fn stdout_of(context: &str, args: &[&str]) -> String {
    output(context, args)
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
        .unwrap_or_default()
}

pub fn namespace_names(context: &str) -> Option<Vec<String>> {
    let out = output(
        context,
        &["get", "ns", "-o", "jsonpath={.items[*].metadata.name}"],
    )
    .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(
        String::from_utf8_lossy(&out.stdout)
            .split_whitespace()
            .map(String::from)
            .collect(),
    )
}

pub fn count_lines(context: &str, args: &[&str]) -> Option<usize> {
    let out = output(context, args).ok()?;
    if !out.status.success() {
        return None;
    }
    Some(
        String::from_utf8_lossy(&out.stdout)
            .lines()
            .filter(|l| !l.trim().is_empty())
            .count(),
    )
}

/// A resource as JSON, or None if it is not there or does not parse.
///
/// There were two of these, differing only in whether the subprocess got the
/// lab's trust settings. Now that every kubectl gets them there is one.
pub fn resource_json(context: &str, resource: &str) -> Option<serde_json::Value> {
    capture(context, &["get", resource, "-o", "json"])
        .ok()
        .and_then(|o| serde_json::from_str(&o).ok())
}

pub fn capture(context: &str, args: &[&str]) -> Result<String> {
    let mut cmd = command();
    cmd.args(["--context", context]).args(args);
    run_capture(&mut cmd)
}

pub fn annotate(
    context: &str,
    resource: &str,
    annotation: &str,
    overwrite: bool,
) -> Result<String> {
    let mut args = vec!["annotate", resource, annotation];
    if overwrite {
        args.push("--overwrite");
    }
    capture(context, &args)
}

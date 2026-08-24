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

/// A kubectl already pointed at a named context.
///
/// kubectl reads an empty `--context` as *unset* and falls back to the
/// kubeconfig's `current-context`, so a lab whose context never resolved would
/// silently run against whatever cluster the operator happens to be pointed
/// at. `lab status` reported such a lab as reachable because some other live
/// cluster answered. Every entrypoint below routes through here, so an
/// unresolved context is an error rather than a different cluster.
pub(super) fn contextual(context: &str) -> std::io::Result<Command> {
    let context = crate::io::kube_context::require_named(context)?;
    let mut cmd = command();
    cmd.args(["--context", context]);
    Ok(cmd)
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

/// Best-effort namespace creation: an existing namespace is not an error, but
/// an unresolved context is, because it would create the namespace somewhere
/// other than the lab.
///
/// # Errors
///
/// Only if `context` is empty. kubectl's own exit is discarded, so a namespace
/// that already exists and a cluster that is unreachable both read as success.
pub fn create_namespace_if_missing(context: &str, namespace: &str) -> Result<()> {
    let mut cmd = contextual(context)?;
    cmd.args(["create", "namespace", namespace]);
    let _ = run_capture(&mut cmd);
    Ok(())
}

/// A TLS Secret manifest, built by kubectl rather than by hand so the base64
/// and field names come from the same place that will read them back.
///
/// # Errors
///
/// If `context` is empty, or kubectl exits non-zero because a PEM file is
/// missing or malformed. `--dry-run=client` means the cluster is not touched,
/// but the context still has to name one.
pub fn render_tls_secret(
    context: &str,
    name: &str,
    namespace: &str,
    cert: &Path,
    key: &Path,
) -> Result<String> {
    let mut cmd = contextual(context)?;
    cmd.args([
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

/// A ConfigMap as JSON, which `kubectl apply` reads as readily as YAML.
///
/// JSON rather than YAML because the values here are PEM blocks and the keys
/// are hostnames: hand-rolling block scalars and quoting rules for those is a
/// way to produce a manifest that parses and says something else.
pub fn render_config_map(
    namespace: &str,
    name: &str,
    data: &std::collections::BTreeMap<&str, &str>,
) -> String {
    serde_json::json!({
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": name,
            "namespace": namespace,
            "labels": { "app.kubernetes.io/managed-by": "catallaxy" },
        },
        "data": data,
    })
    .to_string()
}

#[cfg(test)]
mod config_map_tests {
    use super::render_config_map;
    use std::collections::BTreeMap;

    /// The keys are hostnames and the values are PEM blocks, so the encoding
    /// has to survive dots and embedded newlines without quoting rules being
    /// involved. A manifest that parses and says something else is worse than
    /// one that fails.
    #[test]
    fn a_hostname_key_and_a_pem_value_survive_the_encoding() {
        let mut data = BTreeMap::new();
        data.insert("git.homelab.test", "-----BEGIN CERTIFICATE-----\nMIIB\n");
        let rendered = render_config_map("argocd", "argocd-tls-certs-cm", &data);

        let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();
        assert_eq!(parsed["kind"], "ConfigMap");
        assert_eq!(parsed["metadata"]["namespace"], "argocd");
        assert_eq!(
            parsed["data"]["git.homelab.test"],
            "-----BEGIN CERTIFICATE-----\nMIIB\n"
        );
    }

    /// Two repositories on different hosts share one ConfigMap, so both keys
    /// have to be in it. Writing one object per entry would leave whichever
    /// was applied last.
    #[test]
    fn two_hosts_become_two_keys_of_one_config_map() {
        let mut data = BTreeMap::new();
        data.insert("git.a.test", "pem-a");
        data.insert("git.b.test", "pem-b");
        let parsed: serde_json::Value =
            serde_json::from_str(&render_config_map("argocd", "certs", &data)).unwrap();
        assert_eq!(parsed["data"]["git.a.test"], "pem-a");
        assert_eq!(parsed["data"]["git.b.test"], "pem-b");
    }
}

/// # Errors
///
/// If `context` is empty, or kubectl exits non-zero, in which case its stderr
/// is the message.
pub fn apply_stdin(context: &str, manifest: &[u8]) -> Result<()> {
    let mut cmd = contextual(context)?;
    cmd.args(["apply", "-f", "-"]);
    crate::io::process::run_with_stdin(&mut cmd, manifest)?;
    Ok(())
}

/// # Errors
///
/// If `context` is empty, or kubectl cannot be spawned. A non-zero exit is
/// `Ok`, and is in the returned `status`.
pub fn output(context: &str, args: &[&str]) -> std::io::Result<std::process::Output> {
    contextual(context)?.args(args).output()
}

/// # Errors
///
/// If `context` is empty, or kubectl cannot be spawned. A non-zero exit is
/// `Ok`. Output goes to this process's terminal.
pub fn status(context: &str, args: &[&str]) -> std::io::Result<std::process::ExitStatus> {
    contextual(context)?.args(args).status()
}

/// # Errors
///
/// If `context` is empty, or kubectl cannot be spawned. A non-zero exit is
/// `Ok`, and both of kubectl's streams are discarded, so the status is all the
/// caller gets.
pub fn quiet_status(context: &str, args: &[&str]) -> std::io::Result<std::process::ExitStatus> {
    contextual(context)?
        .args(args)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
}

/// Apply a manifest, reporting whether kubectl accepted it.
///
/// # Errors
///
/// If `context` is empty, kubectl cannot be spawned, or the manifest cannot be
/// written to its stdin. A rejected manifest is `Ok(false)`.
pub fn apply_stdin_succeeded(context: &str, manifest: &[u8]) -> std::io::Result<bool> {
    use std::io::Write;

    let mut child = contextual(context)?
        .args(["apply", "-f", "-"])
        .stdin(Stdio::piped())
        .spawn()?;
    child
        .stdin
        .as_mut()
        .expect("stdin was piped in the command builder above")
        .write_all(manifest)?;
    Ok(child.wait()?.success())
}

/// stdout of a kubectl that ran and succeeded, or None.
///
/// This returned `String` and collapsed both "kubectl failed" and "kubectl
/// printed nothing" into `""`, which is the same conflation that let an
/// unresolved context read as an empty result.
pub fn stdout_of(context: &str, args: &[&str]) -> Option<String> {
    let out = output(context, args).ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).to_string())
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

/// # Errors
///
/// If `context` is empty, or kubectl exits non-zero, in which case its stderr
/// is the message. Use [`stdout_of`] where a failure is an answer.
pub fn capture(context: &str, args: &[&str]) -> Result<String> {
    let mut cmd = contextual(context)?;
    cmd.args(args);
    run_capture(&mut cmd)
}

/// # Errors
///
/// If `context` is empty, or kubectl exits non-zero. Without `overwrite`, an
/// annotation that is already set is one such non-zero exit.
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_context_is_refused_rather_than_meaning_the_current_one() {
        for context in ["", " ", "\t", "\n"] {
            let err = contextual(context).expect_err("an empty context must not build a command");
            assert!(
                err.to_string().contains("current-context"),
                "the error should say what kubectl would have done instead: {err}"
            );
        }
    }

    #[test]
    fn a_named_context_builds_a_command() {
        assert!(contextual("k3d-app").is_ok());
    }

    #[test]
    fn every_entrypoint_refuses_an_empty_context() {
        assert!(output("", &["version"]).is_err());
        assert!(status("", &["version"]).is_err());
        assert!(quiet_status("", &["version"]).is_err());
        assert!(capture("", &["version"]).is_err());
        assert!(apply_stdin("", b"").is_err());
        assert!(apply_stdin_succeeded("", b"").is_err());
        assert!(create_namespace_if_missing("", "ns").is_err());
        assert!(stdout_of("", &["version"]).is_none());
        assert!(namespace_names("").is_none());
        assert!(count_lines("", &["get", "ns"]).is_none());
        assert!(resource_json("", "ns/default").is_none());
    }
}

use std::process::{Command, ExitStatus, Output, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::{Context, Result, bail};
use console::style;

static VERBOSE: AtomicBool = AtomicBool::new(false);

pub fn set_verbose(verbose: bool) {
    VERBOSE.store(verbose, Ordering::Relaxed);
}

/// # Errors
///
/// If `name` is not on `PATH`.
pub fn check_tool(name: &str) -> Result<()> {
    which::which(name).with_context(|| format!("required tool `{name}` not found in PATH"))?;
    Ok(())
}

/// Refuse early if the tools every command needs are missing.
///
/// # Errors
///
/// If `kubectl`, `helm` or `nix` is not on `PATH`, or `colima` is not and this
/// is macOS. Reports the first one missing, not all of them; use
/// [`check_all_tools`] for the whole picture.
pub fn check_required_tools() -> Result<()> {
    let tools = ["kubectl", "helm", "nix"];
    for tool in tools {
        check_tool(tool)?;
    }
    if cfg!(target_os = "macos") {
        check_tool("colima")?;
    }
    Ok(())
}

pub fn check_all_tools() -> Vec<(String, bool, String)> {
    let tools = ["nix", "kubectl", "helm", "kapp", "sops", "k3d", "crane"];

    tools
        .iter()
        .map(|&name| match which::which(name) {
            Ok(path) => (name.to_string(), true, path.display().to_string()),
            Err(_) => (name.to_string(), false, "not found".to_string()),
        })
        .collect()
}

pub fn prepare_env(cmd: &mut Command) {
    super::trust::apply(cmd);
    super::kubeconfig::apply(cmd);
    super::egress::apply(cmd);
}

fn prepare(cmd: &mut Command) {
    super::trust::apply(cmd);
    super::kubeconfig::apply(cmd);
    super::egress::apply(cmd);
    if VERBOSE.load(Ordering::Relaxed) {
        eprintln!("{} {:?}", style("Running:").dim(), cmd);
    }
}

pub fn describe(cmd: &Command) -> String {
    let program = cmd.get_program().to_string_lossy();
    let args: Vec<String> = cmd
        .get_args()
        .map(|a| a.to_string_lossy().to_string())
        .collect();
    if args.is_empty() {
        program.to_string()
    } else {
        format!("{program} {}", args.join(" "))
    }
}

/// Run a command with its output on this process's terminal and no stdin.
///
/// # Errors
///
/// If the command cannot be spawned, or exits non-zero. Its stderr went
/// straight to the terminal, so the message carries only the exit code.
pub fn run_streaming(cmd: &mut Command) -> Result<()> {
    prepare(cmd);

    let status = cmd
        .stdin(Stdio::null())
        .status()
        .with_context(|| format!("could not run `{}`", describe(cmd)))?;

    if !status.success() {
        bail!("`{}` exited {}", describe(cmd), status.code().unwrap_or(-1),);
    }

    Ok(())
}

/// Run a command that may prompt, inheriting stdin as well as stdout.
///
/// # Errors
///
/// If the command cannot be spawned, or exits non-zero.
pub fn run_interactive(cmd: &mut Command) -> Result<()> {
    prepare(cmd);

    let status = cmd
        .status()
        .with_context(|| format!("could not run `{}`", describe(cmd)))?;

    if !status.success() {
        bail!("`{}` exited {}", describe(cmd), status.code().unwrap_or(-1),);
    }

    Ok(())
}

/// Feed `input` to a command and return its stdout.
///
/// # Errors
///
/// If the command cannot be spawned, its stdin cannot be written, or it exits
/// non-zero. Writing to the stdin of a command that has already exited is an
/// error here rather than a broken pipe the caller has to recognise.
pub fn run_with_stdin(cmd: &mut Command, input: &[u8]) -> Result<String> {
    use std::io::Write;

    prepare(cmd);

    let mut child = cmd
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("could not run `{}`", describe(cmd)))?;

    child
        .stdin
        .take()
        .context("stdin was piped but is missing")?
        .write_all(input)
        .with_context(|| format!("writing to the stdin of `{}`", describe(cmd)))?;

    let output = child
        .wait_with_output()
        .with_context(|| format!("waiting for `{}`", describe(cmd)))?;

    if !output.status.success() {
        bail!(
            "`{}` exited {}: {}",
            describe(cmd),
            output.status.code().unwrap_or(-1),
            String::from_utf8_lossy(&output.stderr).trim(),
        );
    }

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

/// Run a command and return its stdout, treating a non-zero exit as failure.
///
/// # Errors
///
/// If the command cannot be spawned, or exits non-zero, in which case its
/// captured stderr is the message. Use [`run_output`] where a non-zero exit is
/// an answer rather than a failure.
pub fn run_capture(cmd: &mut Command) -> Result<String> {
    let output = run_output(cmd)?;

    if !output.status.success() {
        bail!(
            "`{}` exited {}: {}",
            describe(cmd),
            output.status.code().unwrap_or(-1),
            String::from_utf8_lossy(&output.stderr).trim(),
        );
    }

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

/// Run a command and hand back its exit status and both streams.
///
/// # Errors
///
/// Only if the command cannot be spawned. A non-zero exit is `Ok`, so callers
/// have to check `status` themselves.
pub fn run_output(cmd: &mut Command) -> Result<Output> {
    prepare(cmd);

    cmd.stdin(Stdio::null())
        .output()
        .context("Failed to execute command")
}

/// # Errors
///
/// Only if `bin` cannot be spawned. A non-zero exit is `Ok`.
pub fn run_tool(bin: &str, args: &[String]) -> Result<ExitStatus> {
    let mut cmd = Command::new(bin);
    cmd.args(args);
    run_status(&mut cmd)
}

/// # Errors
///
/// Only if the command cannot be spawned. A non-zero exit is `Ok`. Output goes
/// to this process's terminal.
pub fn run_status(cmd: &mut Command) -> Result<ExitStatus> {
    prepare(cmd);

    cmd.status().context("Failed to execute command")
}

use std::process::{Command, ExitStatus, Output, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::{Context, Result, bail};
use console::style;

static VERBOSE: AtomicBool = AtomicBool::new(false);

pub fn set_verbose(verbose: bool) {
    VERBOSE.store(verbose, Ordering::Relaxed);
}

pub fn check_tool(name: &str) -> Result<()> {
    which::which(name).with_context(|| format!("required tool `{name}` not found in PATH"))?;
    Ok(())
}

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
}

fn prepare(cmd: &mut Command) {
    super::trust::apply(cmd);
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

pub fn run_output(cmd: &mut Command) -> Result<Output> {
    prepare(cmd);

    cmd.stdin(Stdio::null())
        .output()
        .context("Failed to execute command")
}

pub fn run_tool(bin: &str, args: &[String]) -> Result<ExitStatus> {
    let mut cmd = Command::new(bin);
    cmd.args(args);
    run_status(&mut cmd)
}

pub fn run_status(cmd: &mut Command) -> Result<ExitStatus> {
    prepare(cmd);

    cmd.status().context("Failed to execute command")
}

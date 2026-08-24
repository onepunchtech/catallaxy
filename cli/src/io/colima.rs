use std::process::{Command, Stdio};

use anyhow::{Context, Result};
use console::style;

use crate::io::process::run_streaming;

pub fn is_macos() -> bool {
    cfg!(target_os = "macos")
}

pub fn docker_socket(profile: &str) -> String {
    let home = crate::io::fs::home_or_tmp();
    format!("unix://{home}/.colima/{profile}/docker.sock")
}

/// # Errors
///
/// Only if `colima` cannot be spawned. A VM that is not running, or a command
/// that fails inside it, is a non-zero `ExitStatus`; both of colima's streams
/// are discarded.
pub fn ssh_exec(profile: &str, args: &[&str]) -> Result<std::process::ExitStatus> {
    let mut cmd_args = vec!["ssh", "--profile", profile, "--"];
    cmd_args.extend_from_slice(args);
    Command::new("colima")
        .args(&cmd_args)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .context("Failed to run colima ssh")
}

pub fn profile_running(profile: &str) -> bool {
    let status = Command::new("colima")
        .args(["status", "--profile", profile])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();

    if matches!(status, Ok(s) if s.success()) {
        return true;
    }

    let home = crate::io::fs::home_or_tmp();
    let sock = format!("{home}/.colima/{profile}/docker.sock");
    std::path::Path::new(&sock).exists()
}

/// Bring up the profile's VM, or confirm it is already up.
///
/// # Errors
///
/// If `colima` cannot be spawned, or `colima start` exits non-zero. Raising
/// the inotify limits and installing amd64 binfmt afterwards are best effort,
/// so success does not promise either.
pub fn start(profile: &str, cpu: u64, memory: u64, disk: u64) -> Result<()> {
    if profile_running(profile) {
        println!(
            "{} Colima VM already running (profile: {profile})",
            style(">>>").green()
        );
        ensure_binfmt_amd64(profile);
        return Ok(());
    }

    println!(
        "{} Starting Colima VM (profile: {profile}, cpu: {cpu}, memory: {memory}G, disk: {disk}G)...",
        style(">>>").cyan()
    );

    let mut cmd = Command::new("colima");
    cmd.args([
        "start",
        "--profile",
        profile,
        "--cpu",
        &cpu.to_string(),
        "--memory",
        &memory.to_string(),
        "--disk",
        &disk.to_string(),
        "--runtime",
        "docker",
        "--network-address",
    ]);

    run_streaming(&mut cmd)?;

    let _ = ssh_exec(
        profile,
        &[
            "sudo",
            "sysctl",
            "-w",
            "fs.inotify.max_user_instances=1024",
            "fs.inotify.max_user_watches=1048576",
        ],
    );

    ensure_binfmt_amd64(profile);

    println!("{} Colima VM ready", style(">>>").green());
    Ok(())
}

fn ensure_binfmt_amd64(profile: &str) {
    if cfg!(target_arch = "aarch64") {
        let mut cmd = crate::io::docker::command();
        cmd.args([
            "run",
            "--privileged",
            "--rm",
            "tonistiigi/binfmt",
            "--install",
            "amd64",
        ]);
        crate::io::docker::apply_host(&mut cmd, Some(&docker_socket(profile)));
        let _ = cmd.stdout(Stdio::null()).stderr(Stdio::null()).status();
    }
}

pub fn list_json() -> Option<String> {
    let out = Command::new("colima")
        .args(["list", "-j"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).to_string())
}

pub fn address_in_list(list_json: &str) -> Option<String> {
    list_json.lines().find_map(|line| {
        let parsed = serde_json::from_str::<serde_json::Value>(line).ok()?;
        let addr = parsed["address"].as_str()?;
        (!addr.is_empty()).then(|| addr.to_string())
    })
}

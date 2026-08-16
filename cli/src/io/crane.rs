use std::path::Path;
use std::process::Command;

use anyhow::{Context, Result};

use crate::io::process::run_streaming;

pub fn push(tarball: &str, destination: &str, docker_config_dir: Option<&Path>) -> Result<()> {
    let mut cmd = Command::new("crane");
    cmd.args(["push", tarball, destination]);
    if let Some(dir) = docker_config_dir {
        cmd.env("DOCKER_CONFIG", dir);
    }
    run_streaming(&mut cmd)
}

pub fn copy(source: &str, destination: &str) -> Result<std::process::ExitStatus> {
    let mut cmd = Command::new("crane");
    cmd.args(["copy", source, destination]);
    crate::io::process::run_status(&mut cmd)
}

/// The digest `image` resolves to right now.
///
/// Shelled out to rather than fetched over HTTP because the registry side of
/// this is all the parts nobody wants to write twice: bearer-token auth,
/// docker.io's implicit `library/`, a multi-arch index versus a manifest, and
/// the credentials already in `~/.docker/config.json`.
pub fn digest(image: &str) -> Result<String> {
    let mut cmd = Command::new("crane");
    cmd.args(["digest", image]);
    let out = crate::io::process::run_capture(&mut cmd)
        .with_context(|| format!("resolving a digest for {image}"))?;

    let digest = out.trim().to_string();
    if !digest.starts_with("sha256:") {
        anyhow::bail!("crane returned something that is not a digest for {image}: {digest}");
    }
    Ok(digest)
}

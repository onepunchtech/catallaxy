use std::path::Path;
use std::process::Command;

use anyhow::{Context, Result};

use crate::io::process::run_streaming;

/// # Errors
///
/// If `crane` cannot be spawned, or exits non-zero because the registry
/// refused the push or the tarball is not an image.
pub fn push(tarball: &str, destination: &str, docker_config_dir: Option<&Path>) -> Result<()> {
    let mut cmd = Command::new("crane");
    cmd.args(["push", tarball, destination]);
    if let Some(dir) = docker_config_dir {
        cmd.env("DOCKER_CONFIG", dir);
    }
    run_streaming(&mut cmd)
}

/// # Errors
///
/// Only if `crane` cannot be spawned. A registry that refuses either end is a
/// non-zero `ExitStatus`.
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
///
/// # Errors
///
/// If `crane` cannot be spawned, if it exits non-zero because the image or the
/// registry is unreachable, or if what it prints is not a `sha256:` digest.
/// The last is checked because the digest is written into a lock file, where
/// anything else would be pinned as though it were one.
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

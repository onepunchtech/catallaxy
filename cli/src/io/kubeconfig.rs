//! Which kubeconfig the lab's tools write and read.
//!
//! One `~/.kube/config` is written by three parties with no coordination: this
//! CLI, k3d's own merge, and talosctl's. Each does a read-modify-write, so two
//! labs coming up at the same time can leave a well-formed file missing one of
//! them. A lock would serialise ours and reach neither of theirs.
//!
//! So the lab gets its own file and every spawned tool is pointed at it, the
//! same way `trust` points them at the lab's CA bundle. Paths that differ
//! cannot lose each other's entries, and nothing has to be held.
//!
//! The operator's own `~/.kube/config` is left alone. `cata lab env` hands the
//! shell the same `KUBECONFIG` the CLI hands its tools.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{OnceLock, RwLock};

use anyhow::{Context, Result};

use crate::host::state::lab_kubeconfig_path;

fn active() -> &'static RwLock<Option<PathBuf>> {
    static ACTIVE: OnceLock<RwLock<Option<PathBuf>>> = OnceLock::new();
    ACTIVE.get_or_init(|| RwLock::new(None))
}

/// Point every tool this process spawns at the lab's kubeconfig.
///
/// Creates the file if it is missing, because `kubectl config delete-context`
/// and k3d's merge both want something to read, and a lab's first run has
/// nothing yet.
///
/// # Errors
///
/// If the lab's state directory cannot be created, or the empty kubeconfig
/// cannot be written.
///
/// # Panics
///
/// If the process-wide lock holding the active path is poisoned.
pub fn activate(lab_name: &str) -> Result<PathBuf> {
    let path = lab_kubeconfig_path(lab_name);

    if !path.exists() {
        let parent = path.parent().expect("lab kubeconfig always has a parent");
        std::fs::create_dir_all(parent)
            .with_context(|| format!("creating {}", parent.display()))?;
        crate::io::fs::write_private(&path, b"apiVersion: v1\nkind: Config\n")
            .with_context(|| format!("creating {}", path.display()))?;
    }

    let mut guard = active().write().expect("kubeconfig state lock poisoned");
    *guard = Some(path.clone());
    Ok(path)
}

pub fn active_path() -> Option<PathBuf> {
    let guard = active().read().expect("kubeconfig state lock poisoned");
    guard.clone()
}

pub fn env_pairs(path: &Path) -> Vec<(&'static str, OsString)> {
    vec![("KUBECONFIG", OsString::from(path))]
}

pub fn apply(cmd: &mut Command) {
    let Some(path) = active_path() else {
        return;
    };
    for (k, v) in env_pairs(&path) {
        cmd.env(k, v);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The whole claim to concurrency safety is that two labs never name the
    /// same file. Nothing else in the design holds if this does not.
    #[test]
    fn two_labs_never_share_a_kubeconfig() {
        let a = lab_kubeconfig_path("minimal.local");
        let b = lab_kubeconfig_path("minimal.talos");
        assert_ne!(a, b);
        assert!(a.to_string_lossy().contains("minimal.local"));
        assert!(b.to_string_lossy().contains("minimal.talos"));
    }

    #[test]
    fn the_only_variable_handed_over_is_kubeconfig() {
        let pairs = env_pairs(Path::new("/tmp/x/config"));
        let names: Vec<&str> = pairs.iter().map(|(k, _)| *k).collect();
        assert_eq!(names, vec!["KUBECONFIG"]);
    }
}

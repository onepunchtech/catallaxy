use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};

pub fn home_dir() -> Result<PathBuf> {
    match std::env::var("HOME") {
        Ok(h) if !h.is_empty() => Ok(PathBuf::from(h)),
        _ => bail!(
            "HOME is not set, so there is no home directory to read or write. \
             Set HOME and re-run; falling back to /tmp would put lab state and \
             credentials somewhere nothing else looks."
        ),
    }
}

pub fn read_to_string(path: impl AsRef<Path>) -> std::io::Result<String> {
    std::fs::read_to_string(path)
}

pub fn read(path: impl AsRef<Path>) -> std::io::Result<Vec<u8>> {
    std::fs::read(path)
}

pub fn write(path: impl AsRef<Path>, contents: impl AsRef<[u8]>) -> std::io::Result<()> {
    std::fs::write(path, contents)
}

pub fn copy(from: impl AsRef<Path>, to: impl AsRef<Path>) -> std::io::Result<u64> {
    std::fs::copy(from, to)
}

// cp, not a recursive walk: -L dereferences the symlinks a Nix-rendered
// manifest tree is full of, and that is the point of the copy.
pub fn copy_tree_dereferencing(source: &str, target: &Path) -> Result<()> {
    let status = std::process::Command::new("cp")
        .args(["-rL"])
        .arg(source)
        .arg(target)
        .status()
        .context("Failed to copy manifests")?;
    if !status.success() {
        bail!("Failed to copy manifests to repo");
    }
    Ok(())
}

pub fn remove_dir_all(path: impl AsRef<Path>) -> std::io::Result<()> {
    std::fs::remove_dir_all(path)
}

// The dry-run path has always shelled out to `find` and dropped both its
// status and, since it inherits stdout, nothing else. Preserved as-is rather
// than deleted, because deleting it changes what a dry run prints.
pub fn list_yaml_files(root: &str) {
    let _ = std::process::Command::new("find")
        .args([root, "-type", "f", "-name", "*.yaml"])
        .status();
}

pub fn gunzip_to(archive: &Path, target: &Path) -> Result<bool> {
    let outfile = std::fs::File::create(target)?;
    let status = std::process::Command::new("gunzip")
        .arg("-c")
        .arg(archive)
        .stdout(outfile)
        .status()
        .context("running gunzip")?;
    Ok(status.success())
}

pub fn open(path: impl AsRef<Path>) -> std::io::Result<std::fs::File> {
    std::fs::File::open(path)
}

pub fn metadata(path: impl AsRef<Path>) -> std::io::Result<std::fs::Metadata> {
    std::fs::metadata(path)
}

pub fn read_dir(path: impl AsRef<Path>) -> std::io::Result<std::fs::ReadDir> {
    std::fs::read_dir(path)
}

pub fn create_dir_all(path: impl AsRef<Path>) -> std::io::Result<()> {
    std::fs::create_dir_all(path)
}

pub fn write_private(path: &Path, contents: &[u8]) -> Result<()> {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)
        .with_context(|| format!("creating {}", path.display()))?;

    std::io::Write::write_all(&mut file, contents)
        .with_context(|| format!("writing {}", path.display()))?;

    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
        .with_context(|| format!("restricting {}", path.display()))
}

pub fn env_var(name: &str) -> Option<String> {
    std::env::var(name).ok()
}

pub fn temp_root() -> String {
    std::env::var("TMPDIR").unwrap_or_else(|_| "/tmp".into())
}

pub fn kubeconfig_path() -> String {
    std::env::var("KUBECONFIG").unwrap_or_else(|_| {
        format!(
            "{}/.kube/config",
            std::env::var("HOME").unwrap_or_else(|_| "/root".into())
        )
    })
}

pub fn home_or_tmp() -> String {
    // Five callers wanted this before it had a name, and they all fell back to
    // /tmp rather than failing. home_dir() is the accessor that refuses to.
    std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string())
}

pub fn set_mode(path: impl AsRef<Path>, mode: u32) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))
}

pub fn write_atomic(path: &Path, contents: &[u8]) -> Result<()> {
    let parent = path
        .parent()
        .with_context(|| format!("{} has no parent directory", path.display()))?;
    std::fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;

    let tmp = parent.join(format!(
        ".{}.tmp.{}",
        path.file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| "file".to_string()),
        std::process::id(),
    ));

    std::fs::write(&tmp, contents).with_context(|| format!("writing {}", tmp.display()))?;

    // Clean up before building the message, not inside it: with_context's
    // closure runs only on the error path today, and swapping it for context()
    // would silently leave the temp file behind.
    if let Err(e) = std::fs::rename(&tmp, path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(e).with_context(|| format!("replacing {}", path.display()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_atomic_write_leaves_no_temp_file_behind() {
        let dir = std::env::temp_dir().join(format!("cata-fs-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("test dir");
        let target = dir.join("config");

        write_atomic(&target, b"first").expect("first write");
        write_atomic(&target, b"second").expect("second write");

        assert_eq!(std::fs::read(&target).expect("read back"), b"second");
        let leftovers: Vec<_> = std::fs::read_dir(&dir)
            .expect("read dir")
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().to_string())
            .filter(|n| n != "config")
            .collect();
        assert!(leftovers.is_empty(), "left behind: {leftovers:?}");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn writing_creates_missing_parents() {
        let dir = std::env::temp_dir().join(format!("cata-fs-nested-{}", std::process::id()));
        let target = dir.join("a").join("b").join("config");

        write_atomic(&target, b"hello").expect("nested write");

        assert_eq!(std::fs::read(&target).expect("read back"), b"hello");
        let _ = std::fs::remove_dir_all(&dir);
    }
}

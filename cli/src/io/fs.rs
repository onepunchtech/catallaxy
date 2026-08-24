use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};

/// # Errors
///
/// If `HOME` is unset or empty. Deliberately not a fallback: see the message.
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

/// # Errors
///
/// Whatever [`std::fs::read_to_string`] returns: the path is missing, is not
/// readable by this user, or does not hold UTF-8.
pub fn read_to_string(path: impl AsRef<Path>) -> std::io::Result<String> {
    std::fs::read_to_string(path)
}

/// # Errors
///
/// Whatever [`std::fs::read`] returns: the path is missing or not readable by
/// this user.
pub fn read(path: impl AsRef<Path>) -> std::io::Result<Vec<u8>> {
    std::fs::read(path)
}

/// # Errors
///
/// Whatever [`std::fs::write`] returns: the parent directory does not exist,
/// or the path is not writable by this user. Parents are not created.
pub fn write(path: impl AsRef<Path>, contents: impl AsRef<[u8]>) -> std::io::Result<()> {
    std::fs::write(path, contents)
}

/// # Errors
///
/// Whatever [`std::fs::copy`] returns: `from` is missing or unreadable, or
/// `to` is not writable. Follows symlinks on both sides.
pub fn copy(from: impl AsRef<Path>, to: impl AsRef<Path>) -> std::io::Result<u64> {
    std::fs::copy(from, to)
}

/// Copy a tree, resolving symlinks into real files.
///
/// `cp`, not a recursive walk: `-L` dereferences the symlinks a Nix-rendered
/// manifest tree is full of, and that is the point of the copy.
///
/// # Errors
///
/// If `cp` cannot be spawned, or exits non-zero because the source is missing
/// or the target is not writable.
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

/// # Errors
///
/// Whatever [`std::fs::remove_dir_all`] returns, including `NotFound` when the
/// directory is already gone. Callers that treat absence as success have to
/// say so themselves.
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

/// Decompress `archive` into `target`, reporting whether gunzip was happy.
///
/// # Errors
///
/// If `target` cannot be created, or `gunzip` cannot be spawned. A non-zero
/// exit is `Ok(false)`, so a caller that treats a corrupt archive as fatal has
/// to check the bool.
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

/// # Errors
///
/// Whatever [`std::fs::File::open`] returns: the path is missing or not
/// readable by this user. Read-only; use [`write_private`] to create.
pub fn open(path: impl AsRef<Path>) -> std::io::Result<std::fs::File> {
    std::fs::File::open(path)
}

/// # Errors
///
/// Whatever [`std::fs::metadata`] returns: the path is missing, or a component
/// of it is not traversable by this user. Follows symlinks.
pub fn metadata(path: impl AsRef<Path>) -> std::io::Result<std::fs::Metadata> {
    std::fs::metadata(path)
}

/// # Errors
///
/// Whatever [`std::fs::read_dir`] returns: the path is missing, is not a
/// directory, or is not readable. Errors on individual entries surface later,
/// from the iterator. [`dir_entry_names`] is the form that treats a missing
/// directory as empty.
pub fn read_dir(path: impl AsRef<Path>) -> std::io::Result<std::fs::ReadDir> {
    std::fs::read_dir(path)
}

/// # Errors
///
/// Whatever [`std::fs::create_dir_all`] returns: some component of the path
/// exists and is not a directory, or a parent is not writable. An existing
/// directory is success. Modes are left to the umask; use
/// [`create_dir_private`] when the contents are secret.
pub fn create_dir_all(path: impl AsRef<Path>) -> std::io::Result<()> {
    std::fs::create_dir_all(path)
}

/// Make a file readable by anyone who is handed it, 0644.
///
/// # Errors
///
/// If the path is missing, or this user does not own it.
pub fn make_readable(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o644))
}

/// A directory only its owner may enter.
///
/// For somewhere holding a private key that a container has to read. A bind
/// mount hands the file to the container and the kernel checks its mode
/// against the container's uid, not against the directory it came from, so a
/// key that a container can read cannot be protected by its own mode. The
/// directory is what keeps other users on this machine out.
///
/// # Errors
///
/// If the directory cannot be created, or its mode cannot be set afterwards.
/// A directory that already exists is reset to 0700 rather than left alone.
pub fn create_dir_private(path: impl AsRef<Path>) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;

    let path = path.as_ref();
    std::fs::create_dir_all(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))
}

/// Write a file only its owner may read, 0600.
///
/// # Errors
///
/// If the file cannot be opened, written, or restricted. The mode is set both
/// at open time and again afterwards, so an existing file with a wider mode is
/// narrowed rather than inherited. Parents are not created.
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

/// The kubeconfig to read, in the order that answers honestly.
///
/// The active lab first: once a lab is resolved, its clusters are in its own
/// file and nowhere else. Then `$KUBECONFIG`, then the default. This used to
/// honour `$KUBECONFIG` on read while `merge_kubeconfig` wrote to
/// `~/.kube/config` regardless, so the obvious way to keep a lab out of your
/// own kubeconfig worked in one direction only.
pub fn kubeconfig_path() -> String {
    if let Some(path) = crate::io::kubeconfig::active_path() {
        return path.to_string_lossy().into_owned();
    }
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

/// # Errors
///
/// If the path is missing, or this user does not own it.
pub fn set_mode(path: impl AsRef<Path>, mode: u32) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))
}

/// Replace a file in one step, so a reader never sees half of it.
///
/// # Errors
///
/// If `path` has no parent, or the parent cannot be created, or the temp file
/// cannot be written, or the rename fails. A failed rename removes the temp
/// file first, so an error never leaves one behind.
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

/// Temp directories holding plaintext, so an interrupt can still erase them.
///
/// `tempfile` cleans up in `Drop`, which a signal never runs. `lab up` holds
/// decrypted secret projections for the length of a deploy, so a Ctrl-C used
/// to leave them in $TMPDIR.
static SECURE_TEMPDIRS: std::sync::Mutex<Vec<std::path::PathBuf>> =
    std::sync::Mutex::new(Vec::new());

/// A 0700 temp directory whose path is remembered for `erase_secure_tempdirs`.
///
/// The returned handle still erases on drop; the registry is what covers the
/// paths drop never runs for.
///
/// # Errors
///
/// If `$TMPDIR` is missing or not writable, so no directory can be made. A
/// poisoned registry lock is not an error: the directory is returned and still
/// erases on drop.
pub fn secure_tempdir() -> Result<tempfile::TempDir> {
    use std::os::unix::fs::PermissionsExt;

    let dir = tempfile::Builder::new()
        .prefix("cata-")
        .permissions(std::fs::Permissions::from_mode(0o700))
        .tempdir()
        .context("creating a private temp directory")?;

    if let Ok(mut dirs) = SECURE_TEMPDIRS.lock() {
        dirs.push(dir.path().to_path_buf());
    }
    Ok(dir)
}

/// Remove every registered temp directory, ignoring ones already gone.
///
/// Safe to call twice: `main` calls it on the way out and the signal handler
/// calls it on the way down.
pub fn erase_secure_tempdirs() {
    let Ok(mut dirs) = SECURE_TEMPDIRS.lock() else {
        return;
    };
    for dir in dirs.drain(..) {
        let _ = std::fs::remove_dir_all(&dir);
    }
}

#[cfg(test)]
mod secure_tempdir_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn it_is_private_to_the_user() {
        let dir = secure_tempdir().unwrap();
        let mode = std::fs::metadata(dir.path()).unwrap().permissions().mode();
        assert_eq!(
            mode & 0o777,
            0o700,
            "a plaintext directory must not be readable by others"
        );
    }

    #[test]
    fn erasing_removes_it_without_waiting_for_drop() {
        let dir = secure_tempdir().unwrap();
        let path = dir.path().to_path_buf();
        std::fs::write(path.join("secret"), b"plaintext").unwrap();
        assert!(path.exists());

        erase_secure_tempdirs();
        assert!(
            !path.exists(),
            "a registered directory must be gone after erasing"
        );
    }

    #[test]
    fn erasing_twice_is_not_an_error() {
        let _dir = secure_tempdir().unwrap();
        erase_secure_tempdirs();
        erase_secure_tempdirs();
    }
}

/// Names of the entries directly under a directory, or empty if it cannot be
/// read. A missing directory is not an error: it means nothing is there.
pub fn dir_entry_names(path: impl AsRef<Path>) -> Vec<String> {
    let Ok(entries) = std::fs::read_dir(path) else {
        return Vec::new();
    };
    entries
        .filter_map(|e| e.ok())
        .filter_map(|e| e.file_name().into_string().ok())
        .collect()
}

/// # Errors
///
/// Whatever [`std::fs::remove_file`] returns, including `NotFound` when the
/// file is already gone.
pub fn remove_file(path: impl AsRef<Path>) -> std::io::Result<()> {
    std::fs::remove_file(path)
}

/// One line from stdin, for a confirmation prompt.
///
/// # Errors
///
/// If stdin is not readable or does not hold UTF-8. Closed stdin is `Ok("")`,
/// so a caller answering a prompt has to treat empty as no.
pub fn read_line() -> std::io::Result<String> {
    let mut line = String::new();
    std::io::stdin().read_line(&mut line)?;
    Ok(line)
}

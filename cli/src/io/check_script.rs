use std::ffi::OsStr;
use std::path::Path;
use std::process::Command;

/// Run a check script, retrying past the window where it is still being
/// written.
///
/// # Errors
///
/// If the script cannot be spawned. `ETXTBSY` is retried up to five times
/// first, because the script was rendered moments ago and the kernel may still
/// hold it open for writing. A check that runs and fails is a non-zero status
/// in the returned `Output`.
pub fn run(script: &Path, env: &[(&str, &OsStr)]) -> std::io::Result<std::process::Output> {
    const ETXTBSY: i32 = 26;
    const ATTEMPTS: usize = 5;

    let mut cmd = Command::new(script);
    for (name, value) in env {
        cmd.env(name, value);
    }

    for attempt in 1..=ATTEMPTS {
        match cmd.output() {
            // The script was written moments ago and the kernel may still hold
            // it open for writing.
            Err(e) if e.raw_os_error() == Some(ETXTBSY) && attempt < ATTEMPTS => {
                std::thread::sleep(std::time::Duration::from_millis(10 * attempt as u64));
            }
            other => return other,
        }
    }
    unreachable!("the loop returns on its final attempt")
}

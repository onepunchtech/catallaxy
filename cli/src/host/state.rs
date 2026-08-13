use std::fs;
use std::net::ToSocketAddrs;
use std::path::PathBuf;

use anyhow::{Context, Result, bail};

use crate::domain::HostProjection;
use console::style;

pub fn wait_for_dns(host: &str, timeout: std::time::Duration) -> Result<()> {
    let deadline = std::time::Instant::now() + timeout;
    let probe = format!("{host}:443");
    let mut printed_waiting = false;
    loop {
        let resolved = probe
            .as_str()
            .to_socket_addrs()
            .ok()
            .and_then(|mut iter| iter.next())
            .is_some();
        if resolved {
            return Ok(());
        }
        if std::time::Instant::now() >= deadline {
            bail!(
                "'{host}' did not resolve within {}s. Check the lab's mesh with \
                 `cata lab ops -- netbird status` (a bare `netbird status` inspects \
                 your own daemon, not this lab's)",
                timeout.as_secs(),
            );
        }
        if !printed_waiting {
            println!(
                "{} Waiting for '{host}' to resolve via mesh DNS...",
                style(">>>").yellow()
            );
            printed_waiting = true;
        }
        std::thread::sleep(std::time::Duration::from_secs(2));
    }
}

pub fn service_state_dir(lab_name: &str, svc_name: &str) -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home)
        .join(".local/share/catallaxy/labs")
        .join(lab_name)
        .join(svc_name)
}

pub fn lab_state_dir(lab_name: &str) -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home)
        .join(".local/share/catallaxy/labs")
        .join(lab_name)
}

pub fn project_host_secrets(
    projections: &[HostProjection],
    cache: &crate::domain::SecretsCache,
    lab_name: &str,
) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;

    if projections.is_empty() {
        return Ok(());
    }

    let state_dir = lab_state_dir(lab_name);
    let mut written = 0usize;
    let mut skipped = 0usize;

    for entry in projections {
        let HostProjection {
            secret_name,
            store,
            key,
            host_path: path_template,
            ..
        } = entry;

        let value = match cache
            .get(store)
            .and_then(|s| s.get(secret_name))
            .and_then(|sec| sec.get(key))
        {
            Some(v) => v,
            None => {
                println!(
                    "{} hostProjection {}/{}/{}: not in decrypted store, skipping",
                    style(">>>").yellow(),
                    store,
                    secret_name,
                    key,
                );
                continue;
            }
        };

        let resolved = path_template.replace("$LAB_STATE_DIR", &state_dir.to_string_lossy());
        let target = PathBuf::from(resolved);

        if target.exists()
            && let Ok(existing) = fs::read_to_string(&target)
            && existing == *value
        {
            skipped += 1;
            continue;
        }

        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).with_context(|| {
                format!(
                    "creating parent dir for host-projection {}",
                    target.display()
                )
            })?;
        }
        fs::write(&target, value)
            .with_context(|| format!("writing host-projection to {}", target.display()))?;
        let mode: u32 = if key.ends_with(".crt") { 0o644 } else { 0o600 };
        fs::set_permissions(&target, fs::Permissions::from_mode(mode))
            .with_context(|| format!("chmod {:o} on {}", mode, target.display()))?;
        println!(
            "{} wrote {} (mode {:o})",
            style(">>>").green(),
            target.display(),
            mode,
        );
        written += 1;
    }

    if written > 0 || skipped > 0 {
        println!(
            "{} host-projections: {} written, {} unchanged",
            style(">>>").cyan(),
            written,
            skipped,
        );
    }
    Ok(())
}

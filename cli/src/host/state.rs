use std::path::PathBuf;

use anyhow::{Context, Result};

use crate::domain::HostProjection;
use console::style;

/// Where every lab's state lives, relative to `$HOME`.
///
/// The Nix side spells this too, to tell an operator where their CA is, and
/// `state-layout-agrees-with-nix` fails the build if the two drift.
pub const LABS_DIR: &str = ".local/share/catallaxy/labs";

/// Where per-cluster PKI lives, relative to `$HOME`.
pub const PKI_DIR: &str = ".local/share/catallaxy/pki";

/// Where a stack's working directory and local state live, relative to `$HOME`.
///
/// Deliberately not under `LABS_DIR`. `cata lab cleanup` removes a lab's state
/// directory wholesale, and a local backend keeps the only record of what was
/// created in a cloud account. Deleting that does not delete the resources, it
/// just loses track of them, so the two live apart and `cleanup` has to ask
/// before it can orphan anything.
pub const INFRA_DIR: &str = ".local/share/catallaxy/infra";

/// The service directory the lab CA is written to.
pub const PROXY_SERVICE: &str = "proxy";

/// The lab CA certificate's name inside the proxy directory.
pub const CA_CERT: &str = "ca.crt";

pub fn service_state_dir(lab_name: &str, svc_name: &str) -> PathBuf {
    lab_state_dir(lab_name).join(svc_name)
}

pub fn lab_state_dir(lab_name: &str) -> PathBuf {
    let home = crate::io::fs::home_or_tmp();
    PathBuf::from(home).join(LABS_DIR).join(lab_name)
}

/// The lab CA certificate that signs the ingress and every in-cluster issuer.
///
/// Seven call sites composed this path themselves and three of them bypassed
/// the helper that already existed.
pub fn lab_ca_path(lab_name: &str) -> PathBuf {
    service_state_dir(lab_name, PROXY_SERVICE).join(CA_CERT)
}

/// The kubeconfig this lab's clusters are written into.
///
/// Per lab, and inside `lab_state_dir` so teardown already removes it. The
/// alternative is one `~/.kube/config` that k3d, talosctl and the CLI all
/// read-modify-write with no coordination: the write is atomic, the sequence
/// is not, so two labs coming up together can leave a well-formed file missing
/// one of them. Different paths cannot lose each other, and unlike a lock this
/// also covers the merges k3d and talosctl do in their own processes, which
/// nothing of ours could serialise.
pub fn lab_kubeconfig_path(lab_name: &str) -> PathBuf {
    lab_state_dir(lab_name).join("kube").join("config")
}

/// The directory the provisioning tool runs in for one stack.
pub fn infra_work_dir(lab_name: &str, stack: &str) -> PathBuf {
    let home = crate::io::fs::home_or_tmp();
    PathBuf::from(home)
        .join(INFRA_DIR)
        .join(lab_name)
        .join(stack)
}

pub fn cluster_pki_dir(cluster_name: &str) -> PathBuf {
    let home = crate::io::fs::home_or_tmp();
    PathBuf::from(home).join(PKI_DIR).join(cluster_name)
}

pub fn project_host_secrets(
    projections: &[HostProjection],
    cache: &crate::domain::SecretsCache,
    lab_name: &str,
) -> Result<()> {
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
            && let Ok(existing) = crate::io::fs::read_to_string(&target)
            && existing == *value
        {
            skipped += 1;
            continue;
        }

        if let Some(parent) = target.parent() {
            crate::io::fs::create_dir_all(parent).with_context(|| {
                format!(
                    "creating parent dir for host-projection {}",
                    target.display()
                )
            })?;
        }
        crate::io::fs::write(&target, value)
            .with_context(|| format!("writing host-projection to {}", target.display()))?;
        let mode: u32 = if key.ends_with(".crt") { 0o644 } else { 0o600 };
        crate::io::fs::set_mode(&target, mode)
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

/// Where the shape a cluster was built from is recorded.
pub fn cluster_shape_path(lab_name: &str, cluster_name: &str) -> PathBuf {
    lab_state_dir(lab_name)
        .join("clusters")
        .join(format!("{cluster_name}.json"))
}

pub fn write_cluster_shape(
    lab_name: &str,
    cluster_name: &str,
    shape: &crate::domain::cluster_shape::ClusterShape,
) -> anyhow::Result<()> {
    use anyhow::Context;
    let path = cluster_shape_path(lab_name, cluster_name);
    if let Some(parent) = path.parent() {
        crate::io::fs::create_dir_all(parent)
            .with_context(|| format!("creating {}", parent.display()))?;
    }
    crate::io::fs::write_atomic(&path, serde_json::to_string_pretty(shape)?.as_bytes())
        .with_context(|| format!("recording the shape of '{cluster_name}'"))
}

/// The recorded shape, or None if there is not one this catallaxy understands.
pub fn read_cluster_shape(
    lab_name: &str,
    cluster_name: &str,
) -> Option<crate::domain::cluster_shape::ClusterShape> {
    let raw = crate::io::fs::read_to_string(cluster_shape_path(lab_name, cluster_name)).ok()?;
    let shape: crate::domain::cluster_shape::ClusterShape = serde_json::from_str(&raw).ok()?;
    (shape.schema_version == crate::domain::cluster_shape::SCHEMA_VERSION).then_some(shape)
}

/// Where a lab records what it put on this machine.
pub fn lab_record_path(lab_name: &str) -> PathBuf {
    lab_state_dir(lab_name).join("lab.json")
}

pub fn write_lab_record(record: &crate::domain::lab_record::LabRecord) -> anyhow::Result<()> {
    use anyhow::Context;
    let path = lab_record_path(&record.lab);
    if let Some(parent) = path.parent() {
        crate::io::fs::create_dir_all(parent)
            .with_context(|| format!("creating {}", parent.display()))?;
    }
    crate::io::fs::write_atomic(&path, serde_json::to_string_pretty(record)?.as_bytes())
        .with_context(|| format!("recording what lab '{}' put here", record.lab))
}

/// The record, or None if there is not one this catallaxy understands.
pub fn read_lab_record(lab_name: &str) -> Option<crate::domain::lab_record::LabRecord> {
    let raw = crate::io::fs::read_to_string(lab_record_path(lab_name)).ok()?;
    let record: crate::domain::lab_record::LabRecord = serde_json::from_str(&raw).ok()?;
    (record.schema_version == crate::domain::lab_record::SCHEMA_VERSION).then_some(record)
}

/// Every lab that has left a record on this machine.
pub fn list_lab_records() -> Vec<crate::domain::lab_record::LabRecord> {
    let root = PathBuf::from(crate::io::fs::home_or_tmp()).join(LABS_DIR);
    crate::io::fs::dir_entry_names(&root)
        .into_iter()
        .filter_map(|name| read_lab_record(&name))
        .collect()
}

/// Forget that a lab has anything on this machine.
///
/// Only the record. The rest of the state directory holds the lab's CA key,
/// which the host trust store references and which deliberately survives a
/// destroy/up cycle; throwing it away would mint a new CA every time and leave
/// the old one trusted. `lab cleanup` removes the directory when asked to.
pub fn forget_lab_record(lab_name: &str) {
    let _ = crate::io::fs::remove_file(lab_record_path(lab_name));
}

/// Everything a lab left in its state directory, including its CA.
/// Remove everything a lab left in its state directory.
///
/// This can genuinely fail: the registry writes its cache as another uid, so
/// parts of it are not the operator's to delete. The caller reports what is
/// left rather than claiming it went.
pub fn forget_lab_state(lab_name: &str) -> std::io::Result<()> {
    crate::io::fs::remove_dir_all(lab_state_dir(lab_name))
}

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{OnceLock, RwLock};

use anyhow::{Context, Result};
use console::style;

use crate::commands::lab::state::service_state_dir;

const SYSTEM_ROOT_CANDIDATES: &[&str] = &[
    "/etc/ssl/certs/ca-certificates.crt",
    "/etc/pki/tls/certs/ca-bundle.crt",
    "/etc/ssl/ca-bundle.pem",
    "/etc/ssl/cert.pem",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    Ready(PathBuf),
    NoLabCa,
    NoSystemRoots,
}

struct Active {
    bundle: PathBuf,
    lab_ca: PathBuf,
}

fn active() -> &'static RwLock<Option<Active>> {
    static ACTIVE: OnceLock<RwLock<Option<Active>>> = OnceLock::new();
    ACTIVE.get_or_init(|| RwLock::new(None))
}

pub fn lab_ca_path(lab_name: &str) -> PathBuf {
    service_state_dir(lab_name, "proxy").join("ca.crt")
}

pub fn bundle_path(lab_name: &str) -> PathBuf {
    service_state_dir(lab_name, "trust").join("bundle.crt")
}

fn system_roots() -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = Vec::new();
    let mut push = |p: PathBuf| {
        if p.is_file() && !is_catallaxy_bundle(&p) && !out.contains(&p) {
            out.push(p);
        }
    };

    for key in [
        "CATALLAXY_SYSTEM_CA_BUNDLE",
        "SSL_CERT_FILE",
        "NIX_SSL_CERT_FILE",
    ] {
        if let Some(v) = std::env::var_os(key) {
            push(PathBuf::from(v));
        }
    }
    for candidate in SYSTEM_ROOT_CANDIDATES {
        push(PathBuf::from(candidate));
    }
    out
}

fn is_catallaxy_bundle(p: &Path) -> bool {
    p.components().any(|c| c.as_os_str() == "catallaxy")
        && p.file_name().is_some_and(|f| f == "bundle.crt")
}

fn pem_blocks(pem: &str) -> Vec<String> {
    const BEGIN: &str = "-----BEGIN CERTIFICATE-----";
    const END: &str = "-----END CERTIFICATE-----";
    let mut out = Vec::new();
    let mut current: Option<Vec<&str>> = None;
    for line in pem.lines() {
        let trimmed = line.trim();
        if trimmed == BEGIN {
            current = Some(vec![trimmed]);
        } else if trimmed == END {
            if let Some(mut block) = current.take() {
                block.push(trimmed);
                out.push(block.join("\n"));
            }
        } else if let Some(block) = current.as_mut() {
            if !trimmed.is_empty() {
                block.push(trimmed);
            }
        }
    }
    out
}

fn merge(roots: &str, lab_ca: &str) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for block in pem_blocks(roots).into_iter().chain(pem_blocks(lab_ca)) {
        if seen.insert(block.clone()) {
            out.push(block);
        }
    }
    out
}

pub fn ensure_bundle(lab_name: &str) -> Result<Outcome> {
    let ca_path = lab_ca_path(lab_name);
    if !ca_path.is_file() {
        return Ok(Outcome::NoLabCa);
    }
    let ca_pem = std::fs::read_to_string(&ca_path)
        .with_context(|| format!("reading lab CA at {}", ca_path.display()))?;

    let roots = system_roots();
    if roots.is_empty() {
        return Ok(Outcome::NoSystemRoots);
    }
    let mut roots_pem = String::new();
    for path in &roots {
        roots_pem.push_str(
            &std::fs::read_to_string(path)
                .with_context(|| format!("reading system roots at {}", path.display()))?,
        );
        roots_pem.push('\n');
    }

    let blocks = merge(&roots_pem, &ca_pem);

    let ca_blocks = pem_blocks(&ca_pem).len();
    if blocks.len() < 2 || blocks.len() <= ca_blocks {
        return Ok(Outcome::NoSystemRoots);
    }

    let contents = format!("{}\n", blocks.join("\n"));
    let bundle = bundle_path(lab_name);
    let dir = bundle.parent().expect("bundle path always has a parent");
    std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;

    let current = std::fs::read_to_string(&bundle).unwrap_or_default();
    if current != contents {
        let tmp = dir.join(".bundle.crt.tmp");
        std::fs::write(&tmp, &contents).with_context(|| format!("writing {}", tmp.display()))?;
        std::fs::rename(&tmp, &bundle)
            .with_context(|| format!("installing {}", bundle.display()))?;
    }

    Ok(Outcome::Ready(bundle))
}

pub fn activate(lab_name: &str) -> Result<Outcome> {
    let outcome = ensure_bundle(lab_name)?;
    if let Outcome::Ready(bundle) = &outcome {
        let mut guard = active().write().expect("trust state lock poisoned");
        *guard = Some(Active {
            bundle: bundle.clone(),
            lab_ca: lab_ca_path(lab_name),
        });
    }
    Ok(outcome)
}

pub fn env_pairs(bundle: &Path, lab_ca: &Path) -> Vec<(&'static str, OsString)> {
    let b = OsString::from(bundle);
    vec![
        ("SSL_CERT_FILE", b.clone()),
        ("CURL_CA_BUNDLE", b.clone()),
        ("GIT_SSL_CAINFO", b.clone()),
        ("REQUESTS_CA_BUNDLE", b.clone()),
        ("NIX_SSL_CERT_FILE", b),
        ("NODE_EXTRA_CA_CERTS", OsString::from(lab_ca)),
    ]
}

pub fn active_bundle() -> Option<PathBuf> {
    let guard = active().read().expect("trust state lock poisoned");
    guard
        .as_ref()
        .map(|s| s.bundle.clone())
        .filter(|b| b.is_file())
}

pub fn apply(cmd: &mut Command) {
    let guard = active().read().expect("trust state lock poisoned");
    let Some(state) = guard.as_ref() else {
        return;
    };
    if !state.bundle.is_file() {
        warn_bundle_vanished(&state.bundle);
        return;
    }
    for (k, v) in env_pairs(&state.bundle, &state.lab_ca) {
        cmd.env(k, v);
    }
}

fn warn_bundle_vanished(bundle: &Path) {
    static WARNED: OnceLock<()> = OnceLock::new();
    if WARNED.set(()).is_ok() {
        eprintln!(
            "{} lab CA bundle disappeared ({}); spawned tools will fall back to \
             the host trust store. Re-run `cata lab up` to rebuild it.",
            style("Warning:").yellow(),
            bundle.display(),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cert(body: &str) -> String {
        format!("-----BEGIN CERTIFICATE-----\n{body}\n-----END CERTIFICATE-----")
    }

    #[test]
    fn pem_blocks_ignores_text_outside_blocks() {
        let input = format!(
            "some human readable preamble\n{}\n\ntrailing note\n{}\n",
            cert("AAAA"),
            cert("BBBB"),
        );
        let blocks = pem_blocks(&input);
        assert_eq!(blocks.len(), 2);
        assert!(blocks[0].contains("AAAA"));
        assert!(blocks[1].contains("BBBB"));
    }

    #[test]
    fn merge_appends_the_lab_ca_after_the_roots() {
        let roots = format!("{}\n{}\n", cert("ROOT1"), cert("ROOT2"));
        let ca = format!("{}\n", cert("LABCA"));
        let merged = merge(&roots, &ca);
        assert_eq!(merged.len(), 3);
        assert!(merged[2].contains("LABCA"));
    }

    #[test]
    fn merge_drops_a_lab_ca_already_present_in_the_roots() {
        let ca = format!("{}\n", cert("LABCA"));
        let roots = format!("{}\n{}", cert("ROOT1"), ca);
        let merged = merge(&roots, &ca);
        assert_eq!(merged.len(), 2);
        assert_eq!(
            merged.iter().filter(|b| b.contains("LABCA")).count(),
            1,
            "lab CA must appear exactly once"
        );
    }

    #[test]
    fn merge_is_idempotent() {
        let roots = format!("{}\n", cert("ROOT1"));
        let ca = format!("{}\n", cert("LABCA"));
        let once = merge(&roots, &ca).join("\n");
        let twice = merge(&once, &ca).join("\n");
        assert_eq!(once, twice);
    }

    #[test]
    fn env_pairs_give_node_the_bare_ca_and_never_set_ssl_cert_dir() {
        let bundle = PathBuf::from("/tmp/bundle.crt");
        let ca = PathBuf::from("/tmp/ca.crt");
        let pairs = env_pairs(&bundle, &ca);

        let node = pairs
            .iter()
            .find(|(k, _)| *k == "NODE_EXTRA_CA_CERTS")
            .expect("NODE_EXTRA_CA_CERTS is set");
        assert_eq!(
            node.1,
            OsString::from(&ca),
            "Node appends, so it gets the bare CA"
        );

        for key in ["SSL_CERT_FILE", "CURL_CA_BUNDLE", "GIT_SSL_CAINFO"] {
            let v = pairs.iter().find(|(k, _)| *k == key).expect("set");
            assert_eq!(v.1, OsString::from(&bundle));
        }

        assert!(
            !pairs.iter().any(|(k, _)| *k == "SSL_CERT_DIR"),
            "SSL_CERT_DIR is deliberately never set; see the module header"
        );
    }

    #[test]
    fn merge_unions_several_root_sources_without_duplicating() {
        let cacert = format!("{}\n{}\n", cert("ROOT1"), cert("ROOT2"));
        let system = format!(
            "{}\n{}\n{}\n",
            cert("ROOT1"),
            cert("ROOT2"),
            cert("CORPORATE")
        );
        let ca = format!("{}\n", cert("LABCA"));
        let merged = merge(&format!("{cacert}{system}"), &ca);
        assert_eq!(merged.len(), 4, "3 distinct roots + the lab CA");
        assert!(
            merged.iter().any(|b| b.contains("CORPORATE")),
            "a root only the host bundle carries must survive"
        );
    }

    #[test]
    fn a_catallaxy_bundle_is_not_mistaken_for_system_roots() {
        assert!(is_catallaxy_bundle(Path::new(
            "/home/x/.local/share/catallaxy/labs/mesh.local/trust/bundle.crt"
        )));
        assert!(!is_catallaxy_bundle(Path::new(
            "/etc/ssl/certs/ca-certificates.crt"
        )));
    }
}

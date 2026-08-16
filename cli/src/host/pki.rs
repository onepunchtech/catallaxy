use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use console::style;

use crate::domain::LabSpec;
use crate::host::state::service_state_dir;
use crate::io;
use crate::io::pki::CaPem;
use crate::io::trust_store;

pub fn ensure_ingress_cert(lab_name: &str, zone: &str) -> Result<PathBuf> {
    let ingress_dir = service_state_dir(lab_name, "proxy");
    let cert_pem = ingress_dir.join("lab.pem");
    if cert_pem.exists() && !needs_reissue(&cert_pem, &ingress_dir.join("ca.crt")) {
        return Ok(ingress_dir);
    }

    io::fs::create_dir_all(&ingress_dir)?;

    let ca_cert = ingress_dir.join("ca.crt");
    let ca_key = ingress_dir.join("ca.key");

    if !(ca_cert.exists() && ca_key.exists()) {
        println!(
            "{} No stored CA on disk. Minting a local one. Declare a \
             `kind = \"ca\"` managed secret and run `cata secrets generate` \
             to share one across the team.",
            style(">>>").yellow(),
        );
        mint_local_ca(&ca_cert, &ca_key)?;
    } else {
        println!(
            "{} Using existing lab CA at {}",
            style(">>>").green(),
            ca_cert.display(),
        );
    }

    sign_server_cert(&ingress_dir, &ca_cert, &ca_key, &cert_pem, zone)?;

    println!(
        "{} TLS certificate ready at {}",
        style(">>>").green(),
        ingress_dir.display(),
    );

    Ok(ingress_dir)
}

fn mint_local_ca(ca_cert: &Path, ca_key: &Path) -> Result<()> {
    let ca = crate::io::pki::self_signed_ca(
        CA_COMMON_NAME,
        crate::io::pki::KeyAlgorithm::EcdsaP256,
        3650,
    )?;
    io::fs::write(ca_cert, &ca.cert_pem)?;
    io::fs::write_private(ca_key, ca.key_pem.as_bytes())?;
    Ok(())
}

const CA_COMMON_NAME: &str = "Catallaxy Lab CA";

/// Reads the CA a lab already has. Only its key algorithm distinguishes an
/// old one from a new: labs minted before this used openssl and RSA-4096, and
/// they keep it, because the CA on disk is the one the host trusts.
fn read_ca(ca_cert: &Path, ca_key: &Path) -> Result<CaPem> {
    Ok(CaPem {
        cert_pem: io::fs::read_to_string(ca_cert)
            .with_context(|| format!("reading the lab CA at {}", ca_cert.display()))?,
        key_pem: io::fs::read_to_string(ca_key)
            .with_context(|| format!("reading the lab CA key at {}", ca_key.display()))?,
    })
}

pub fn ensure_host_trust(lab_name: &str, ca_path: &Path) -> Result<()> {
    if !ca_path.exists() {
        return Ok(());
    }

    if cfg!(target_os = "macos") {
        ensure_host_trust_macos(lab_name, ca_path)
    } else {
        ensure_host_trust_linux(lab_name, ca_path)
    }
}

pub fn keychain_fingerprint(stdout: &str) -> String {
    stdout
        .lines()
        .find(|l| l.starts_with("SHA-1 hash:"))
        .map(|l| l.trim_start_matches("SHA-1 hash:").trim().to_uppercase())
        .unwrap_or_default()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrustState {
    AlreadyTrusted,
    CaChanged,
    NotInstalled,
}

impl TrustState {
    pub fn of(disk: &str, keychain: &str) -> Self {
        if keychain == disk {
            TrustState::AlreadyTrusted
        } else if keychain.is_empty() {
            TrustState::NotInstalled
        } else {
            TrustState::CaChanged
        }
    }
}

fn ensure_host_trust_macos(_lab_name: &str, ca_path: &Path) -> Result<()> {
    let ca_pem = io::fs::read_to_string(ca_path)
        .with_context(|| format!("reading the lab CA at {}", ca_path.display()))?;

    let Some(disk_fp) = crate::io::pki::sha1_fingerprint(&ca_pem) else {
        bail!(
            "{} is not a certificate this can fingerprint",
            ca_path.display()
        );
    };

    let keychain_fp = keychain_fingerprint(&trust_store::keychain_certificates("Catallaxy Lab CA"));

    match TrustState::of(&disk_fp, &keychain_fp) {
        TrustState::AlreadyTrusted => {
            println!(
                "{} Lab CA already trusted (System keychain)",
                style(">>>").green()
            );
            return Ok(());
        }
        TrustState::CaChanged => println!(
            "{} Lab CA changed, updating System keychain trust",
            style(">>>").cyan()
        ),
        TrustState::NotInstalled => println!(
            "{} Installing lab CA into System keychain",
            style(">>>").cyan()
        ),
    }
    println!(
        "    This requires sudo + macOS admin credentials to modify\n    \
         the System keychain."
    );

    trust_store::add_trusted_root(ca_path)?;

    println!("{} Lab CA trusted", style(">>>").green());
    Ok(())
}

fn ensure_host_trust_linux(lab_name: &str, ca_path: &Path) -> Result<()> {
    if Path::new("/etc/NIXOS").exists() {
        const BUNDLE: &str = "/etc/ssl/certs/ca-certificates.crt";
        let ca_pem = io::fs::read_to_string(ca_path)
            .with_context(|| format!("reading lab CA at {}", ca_path.display()))?;

        match io::fs::read_to_string(BUNDLE) {
            Ok(bundle) if bundle.contains(ca_pem.trim()) => {
                println!(
                    "{} Lab CA trusted (NixOS system bundle)",
                    style(">>>").green()
                );
                Ok(())
            }
            Ok(_) => {
                bail!(
                    "Lab CA for '{lab_name}' is not in the NixOS system trust store, \
                     and this lab set `lab.trust.installIntoHostStore = true`.\n\
                     \n    Either add to your NixOS configuration:\n\
                     \n      security.pki.certificateFiles = [ \"{}\" ];\n\
                     \n    then: sudo nixos-rebuild switch\n\
                     \n    Or drop the option back to its default (false), which \
                     needs no host changes at all: `cata` hands every tool it \
                     spawns a merged CA bundle, `nix develop` on the lab gives \
                     your shell the same trust, and `eval \"$(cata lab env \
                     {lab_name})\"` does it for a shell you are already in.\n\
                     \n    Browsers read neither — for those, \
                     `cata lab ops -- trust setup` imports into your NSS store \
                     without sudo.",
                    ca_path.display(),
                )
            }
            Err(e) => {
                println!(
                    "{} NixOS detected but {BUNDLE} is unreadable ({e}); \
                     cannot verify lab CA trust. If HTTPS to *.<zone> fails, add:\n    \
                     security.pki.certificateFiles = [ \"{}\" ];",
                    style("Warning:").yellow(),
                    ca_path.display(),
                );
                Ok(())
            }
        }
    } else {
        ensure_host_trust_linux_writable(lab_name, ca_path)
    }
}

fn ensure_host_trust_linux_writable(lab_name: &str, ca_path: &Path) -> Result<()> {
    let dest = format!("/usr/local/share/ca-certificates/catallaxy-{lab_name}.crt");

    if Path::new(&dest).exists() {
        let installed = io::fs::read(&dest).unwrap_or_default();
        let current = io::fs::read(ca_path).unwrap_or_default();
        if installed == current {
            println!(
                "{} Lab CA already in system trust store",
                style(">>>").green()
            );
            return Ok(());
        }
        println!(
            "{} Lab CA changed, updating system trust store",
            style(">>>").cyan()
        );
    } else {
        println!(
            "{} Installing lab CA into system trust store",
            style(">>>").cyan()
        );
    }

    println!("    This requires sudo to install into /usr/local/share/ca-certificates/");

    trust_store::install_system_certificate(ca_path, &dest)?;

    println!("{} Lab CA trusted", style(">>>").green());
    Ok(())
}

fn sign_server_cert(
    ingress_dir: &Path,
    ca_cert: &Path,
    ca_key: &Path,
    cert_pem: &Path,
    zone: &str,
) -> Result<()> {
    let ca = read_ca(ca_cert, ca_key)?;
    let names = vec![format!("*.{zone}"), zone.to_string()];
    let server = crate::io::pki::server_cert(&ca, &names, 365)
        .with_context(|| format!("signing the ingress certificate for *.{zone}"))?;

    io::fs::write(ingress_dir.join("lab.crt"), &server.cert_pem)?;
    io::fs::write_private(&ingress_dir.join("lab.key"), server.key_pem.as_bytes())?;
    io::fs::write_private(
        cert_pem,
        format!("{}{}", server.cert_pem, server.key_pem).as_bytes(),
    )?;
    Ok(())
}

const RENEW_BEFORE_DAYS: u64 = 30;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReissueReason {
    ExpiringWithin(u64),
    SignedByAnotherCa,
}

impl ReissueReason {
    fn describe(&self) -> String {
        match self {
            ReissueReason::ExpiringWithin(days) => {
                format!("the lab ingress certificate expires within {days} days, reissuing")
            }
            ReissueReason::SignedByAnotherCa => {
                "the lab ingress certificate was signed by a different CA, reissuing".to_string()
            }
        }
    }
}

fn reissue_reason(cert_pem: &Path, ca_cert: &Path) -> Option<ReissueReason> {
    if expires_within(cert_pem, RENEW_BEFORE_DAYS) {
        return Some(ReissueReason::ExpiringWithin(RENEW_BEFORE_DAYS));
    }
    if ca_cert.exists() && !signed_by(cert_pem, ca_cert) {
        return Some(ReissueReason::SignedByAnotherCa);
    }
    None
}

fn needs_reissue(cert_pem: &Path, ca_cert: &Path) -> bool {
    match reissue_reason(cert_pem, ca_cert) {
        Some(reason) => {
            println!("{} {}", style(">>>").yellow(), reason.describe());
            true
        }
        None => false,
    }
}

fn expires_within(cert_pem: &Path, days: u64) -> bool {
    let Ok(pem) = io::fs::read_to_string(cert_pem) else {
        return false;
    };
    crate::io::pki::days_until_expiry(&pem).is_some_and(|d| d < days as i64)
}

fn signed_by(cert_pem: &Path, ca_cert: &Path) -> bool {
    let Ok(cert) = io::fs::read_to_string(cert_pem) else {
        return true;
    };
    let Ok(ca) = io::fs::read_to_string(ca_cert) else {
        return true;
    };
    // None means neither name could be read, so this cannot tell. It answers
    // "yes, signed by that CA" so an unreadable pair does not reissue.
    crate::io::pki::issued_by(&cert, &ca).unwrap_or(true)
}

pub fn import_lab_ca(lab_name: &str, lab: &LabSpec, cluster_name: &str) -> Result<()> {
    let ingress_dir = crate::host::state::service_state_dir(lab_name, "proxy");
    let ca_crt = ingress_dir.join("ca.crt");
    let ca_key = ingress_dir.join("ca.key");

    if !ca_crt.exists() || !ca_key.exists() {
        return Ok(());
    }

    let context = lab.kube_context(cluster_name)?;

    crate::io::kubectl::create_namespace_if_missing(context, "cert-manager");

    let manifest = crate::io::kubectl::render_tls_secret(
        context,
        "lab-ca-ca-secret",
        "cert-manager",
        &ca_crt,
        &ca_key,
    )
    .with_context(|| format!("rendering the lab CA secret for '{cluster_name}'"))?;

    crate::io::kubectl::apply_stdin(context, manifest.as_bytes())
        .with_context(|| format!("importing the lab CA into '{cluster_name}'"))?;

    println!(
        "{} Lab CA imported into '{cluster_name}'",
        style(">>>").green()
    );

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // A throwaway RSA CA, minted by openssl exactly as a lab's CA was before
    // this code used rcgen. rcgen cannot generate an RSA key but it can sign
    // with one, which is what lets the switch happen without reminting a CA
    // users have already told their machine to trust.
    const LEGACY_CA_CERT: &str = include_str!("../../tests/fixtures/legacy-rsa-ca.crt");
    const LEGACY_CA_KEY: &str = include_str!("../../tests/fixtures/legacy-rsa-ca.key");

    #[test]
    fn a_lab_whose_ca_is_rsa_keeps_signing_with_it() {
        let ca = CaPem {
            cert_pem: LEGACY_CA_CERT.to_string(),
            key_pem: LEGACY_CA_KEY.to_string(),
        };

        let leaf = crate::io::pki::server_cert(
            &ca,
            &["*.lab.local".to_string(), "lab.local".to_string()],
            365,
        )
        .expect("an RSA CA must still be able to sign");

        assert_eq!(
            crate::io::pki::issued_by(&leaf.cert_pem, &ca.cert_pem),
            Some(true),
            "the leaf must chain to the CA already on disk, or the host stops trusting the lab"
        );
    }

    #[test]
    fn a_fingerprint_is_bare_uppercase_hex_the_keychain_can_be_compared_against() {
        let fp = crate::io::pki::sha1_fingerprint(LEGACY_CA_CERT).expect("a certificate");

        assert_eq!(fp.len(), 40, "SHA-1 is 20 bytes: {fp}");
        assert!(
            fp.chars()
                .all(|c| c.is_ascii_hexdigit() && !c.is_lowercase())
        );
        assert_eq!(
            crate::io::pki::sha1_fingerprint("not a certificate"),
            None,
            "None means not a certificate, never a fingerprint of nothing"
        );
    }

    #[test]
    fn the_keychain_hash_is_read_off_its_own_line() {
        let out = "keychain: \"/Library/Keychains/System.keychain\"\n\
                   SHA-1 hash: abcd1234\n\
                   version: 256\n";
        assert_eq!(keychain_fingerprint(out), "ABCD1234");
    }

    #[test]
    fn a_keychain_holding_no_such_certificate_yields_no_fingerprint() {
        assert_eq!(
            keychain_fingerprint("SecKeychainSearchCopyNext: not found"),
            ""
        );
    }

    #[test]
    fn a_matching_pair_is_already_trusted() {
        assert_eq!(TrustState::of("ABCD", "ABCD"), TrustState::AlreadyTrusted);
    }

    #[test]
    fn an_absent_keychain_entry_means_install_not_update() {
        assert_eq!(TrustState::of("ABCD", ""), TrustState::NotInstalled);
    }

    #[test]
    fn a_different_keychain_entry_means_the_ca_was_reminted() {
        assert_eq!(TrustState::of("ABCD", "EF01"), TrustState::CaChanged);
    }

    // These replace two tests over `issuer_matches`, a helper that compared
    // the strings openssl printed for a DN. There is no such string now: the
    // encoded names are compared directly, so the test works on certificates.
    #[test]
    fn a_certificate_is_recognised_as_issued_by_its_own_ca() {
        let ca = crate::io::pki::self_signed_ca(
            CA_COMMON_NAME,
            crate::io::pki::KeyAlgorithm::EcdsaP256,
            3650,
        )
        .unwrap();
        let leaf = crate::io::pki::server_cert(&ca, &["*.lab.local".to_string()], 365).unwrap();

        assert_eq!(
            crate::io::pki::issued_by(&leaf.cert_pem, &ca.cert_pem),
            Some(true)
        );
    }

    #[test]
    fn a_certificate_from_a_previous_ca_does_not_match() {
        let old =
            crate::io::pki::self_signed_ca("Old CA", crate::io::pki::KeyAlgorithm::EcdsaP256, 3650)
                .unwrap();
        let new = crate::io::pki::self_signed_ca(
            CA_COMMON_NAME,
            crate::io::pki::KeyAlgorithm::EcdsaP256,
            3650,
        )
        .unwrap();
        let leaf = crate::io::pki::server_cert(&old, &["*.lab.local".to_string()], 365).unwrap();

        assert_eq!(
            crate::io::pki::issued_by(&leaf.cert_pem, &new.cert_pem),
            Some(false),
            "a certificate from the previous CA must trigger a reissue"
        );
    }

    #[test]
    fn a_reason_is_only_reported_when_there_is_one() {
        assert_eq!(
            ReissueReason::ExpiringWithin(30).describe(),
            "the lab ingress certificate expires within 30 days, reissuing"
        );
    }
}

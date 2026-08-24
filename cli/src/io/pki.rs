use anyhow::{Result, bail};
use rcgen::{
    BasicConstraints, CertificateParams, DistinguishedName, DnType, DnValue,
    ExtendedKeyUsagePurpose, IsCa, KeyPair, KeyUsagePurpose, PKCS_ECDSA_P256_SHA256,
    PKCS_ECDSA_P384_SHA384, SanType,
};
use time::{Duration, OffsetDateTime};

pub const CERT_KEY: &str = "ca.crt";
pub const KEY_KEY: &str = "ca.key";

#[derive(Debug, Clone)]
pub struct CaPem {
    pub cert_pem: String,
    pub key_pem: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyAlgorithm {
    EcdsaP256,
    EcdsaP384,
}

impl KeyAlgorithm {
    /// # Errors
    ///
    /// If `name` is not one of the algorithms above.
    pub fn parse(name: &str) -> Result<Self> {
        match name {
            "ecdsa-p256" => Ok(KeyAlgorithm::EcdsaP256),
            "ecdsa-p384" => Ok(KeyAlgorithm::EcdsaP384),
            other => bail!("unsupported key algorithm: {other}"),
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            KeyAlgorithm::EcdsaP256 => "ecdsa-p256",
            KeyAlgorithm::EcdsaP384 => "ecdsa-p384",
        }
    }
}

impl std::fmt::Display for KeyAlgorithm {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// # Errors
///
/// If the platform's random source cannot produce a key.
pub fn key_pair(algorithm: KeyAlgorithm) -> Result<KeyPair> {
    Ok(match algorithm {
        KeyAlgorithm::EcdsaP256 => KeyPair::generate_for(&PKCS_ECDSA_P256_SHA256)?,
        KeyAlgorithm::EcdsaP384 => KeyPair::generate_for(&PKCS_ECDSA_P384_SHA384)?,
    })
}

/// # Errors
///
/// If a key cannot be generated, or the certificate cannot be signed.
pub fn self_signed_ca(cn: &str, algorithm: KeyAlgorithm, days: u32) -> Result<CaPem> {
    let key = key_pair(algorithm)?;
    let params = ca_params(cn, days);
    let cert = params.self_signed(&key)?;

    Ok(CaPem {
        cert_pem: cert.pem(),
        key_pem: key.serialize_pem(),
    })
}

/// A CA constrained to sign leaves only, signed by `root`.
///
/// # Errors
///
/// If the root's key or certificate does not parse, or a key cannot be
/// generated, or the certificate cannot be signed.
pub fn intermediate_ca(
    root: &CaPem,
    cn: &str,
    algorithm: KeyAlgorithm,
    days: u32,
) -> Result<CaPem> {
    let root_key = KeyPair::from_pem(&root.key_pem)?;
    let root_params = CertificateParams::from_ca_cert_pem(&root.cert_pem)
        .map_err(|e| anyhow::anyhow!("the root CA certificate does not parse: {e}"))?;
    let root_cert = root_params.self_signed(&root_key)?;

    let key = key_pair(algorithm)?;
    let mut params = ca_params(cn, days);
    params.is_ca = IsCa::Ca(BasicConstraints::Constrained(0));
    let cert = params.signed_by(&key, &root_cert, &root_key)?;

    Ok(CaPem {
        cert_pem: cert.pem(),
        key_pem: key.serialize_pem(),
    })
}

fn ca_params(cn: &str, days: u32) -> CertificateParams {
    let mut params = CertificateParams::default();
    params.distinguished_name = DistinguishedName::new();
    params
        .distinguished_name
        .push(DnType::CommonName, DnValue::Utf8String(cn.to_string()));
    params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    params.key_usages = vec![
        KeyUsagePurpose::DigitalSignature,
        KeyUsagePurpose::KeyCertSign,
        KeyUsagePurpose::CrlSign,
    ];
    params.not_before = OffsetDateTime::now_utc();
    params.not_after = OffsetDateTime::now_utc() + Duration::days(days as i64);
    params
}

/// A leaf certificate signed by `ca`, serving every name in `dns_names`.
///
/// The CA's key is loaded rather than generated, so a lab that already has an
/// RSA CA on disk keeps signing with it: rcgen cannot mint RSA keys but it
/// can sign with one it is given. That is what lets this replace the openssl
/// invocations without invalidating a CA users have already trusted.
///
/// # Errors
///
/// If the CA's key or certificate does not parse, if any entry in `dns_names`
/// is not a name a SAN can carry, or if the certificate cannot be signed.
pub fn server_cert(ca: &CaPem, dns_names: &[String], days: u32) -> Result<CaPem> {
    let ca_key = KeyPair::from_pem(&ca.key_pem)
        .map_err(|e| anyhow::anyhow!("the CA private key does not parse: {e}"))?;
    let ca_cert = CertificateParams::from_ca_cert_pem(&ca.cert_pem)
        .map_err(|e| anyhow::anyhow!("the CA certificate does not parse: {e}"))?
        .self_signed(&ca_key)?;

    let key = key_pair(KeyAlgorithm::EcdsaP256)?;

    let mut params = CertificateParams::default();
    params.distinguished_name = DistinguishedName::new();
    if let Some(first) = dns_names.first() {
        params
            .distinguished_name
            .push(DnType::CommonName, DnValue::Utf8String(first.clone()));
    }
    params.is_ca = IsCa::NoCa;
    params.key_usages = vec![
        KeyUsagePurpose::DigitalSignature,
        KeyUsagePurpose::KeyEncipherment,
    ];
    params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
    params.subject_alt_names = dns_names
        .iter()
        .map(|n| {
            n.clone().try_into().map(SanType::DnsName).map_err(|e| {
                anyhow::anyhow!("`{n}` is not a DNS name a certificate can carry: {e}")
            })
        })
        .collect::<Result<Vec<_>>>()?;
    params.not_before = OffsetDateTime::now_utc();
    params.not_after = OffsetDateTime::now_utc() + Duration::days(days as i64);

    let cert = params.signed_by(&key, &ca_cert, &ca_key)?;

    Ok(CaPem {
        cert_pem: cert.pem(),
        key_pem: key.serialize_pem(),
    })
}

/// The SHA-1 fingerprint of a certificate, as bare uppercase hex.
///
/// SHA-1 not because it is a good hash but because it is the one the macOS
/// keychain reports, and this exists to compare against that.
pub fn sha1_fingerprint(cert_pem: &str) -> Option<String> {
    use sha1::{Digest, Sha1};

    let (_, parsed) = x509_parser::pem::parse_x509_pem(cert_pem.as_bytes()).ok()?;
    Some(
        Sha1::digest(&parsed.contents)
            .iter()
            .map(|b| format!("{b:02X}"))
            .collect(),
    )
}

/// Whether `cert_pem` was issued by `ca_pem`, or None if either does not parse.
///
/// Compares the encoded names rather than their rendered strings, which is
/// what the openssl-based version did and what made it sensitive to how each
/// tool chose to print a DN.
pub fn issued_by(cert_pem: &str, ca_pem: &str) -> Option<bool> {
    let (_, cert) = x509_parser::pem::parse_x509_pem(cert_pem.as_bytes()).ok()?;
    let (_, ca) = x509_parser::pem::parse_x509_pem(ca_pem.as_bytes()).ok()?;
    Some(cert.parse_x509().ok()?.issuer() == ca.parse_x509().ok()?.subject())
}

/// Days until a PEM certificate expires, negative once it has.
///
/// Parsed rather than shelled out to. The previous implementation asked
/// `openssl` for the date and then GNU `date -d` to turn it into a timestamp,
/// which is not a flag macOS `date` has: it returned nothing there, and a
/// check that cannot tell reported no finding. Three subprocesses for one
/// subtraction, and silently wrong on half the machines that run this.
pub fn days_until_expiry(pem: &str) -> Option<i64> {
    let (_, parsed) = x509_parser::pem::parse_x509_pem(pem.as_bytes()).ok()?;
    let cert = parsed.parse_x509().ok()?;

    let expiry = cert.validity().not_after.timestamp();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_secs() as i64;

    Some((expiry - now) / 86_400)
}

#[cfg(test)]
mod tests {
    use super::*;
    use x509_parser::prelude::*;

    fn der_of(cert_pem: &str) -> Vec<u8> {
        let (_, parsed) =
            x509_parser::pem::parse_x509_pem(cert_pem.as_bytes()).expect("cert is PEM");
        parsed.contents
    }

    #[test]
    fn a_self_signed_ca_is_a_ca_with_the_common_name_it_was_asked_for() {
        let ca = self_signed_ca(
            "Catallaxy Lab CA (mesh.local)",
            KeyAlgorithm::EcdsaP256,
            3650,
        )
        .unwrap();
        let der = der_of(&ca.cert_pem);
        let (_, cert) = X509Certificate::from_der(&der).expect("cert parses");

        assert!(cert.is_ca());
        assert!(
            cert.subject()
                .to_string()
                .contains("Catallaxy Lab CA (mesh.local)")
        );
        assert_eq!(cert.subject(), cert.issuer());
        assert!(ca.key_pem.contains("PRIVATE KEY"));
    }

    // `cata pki init` used to repeat these parameters inline and had drifted
    // from this function, so what a CA could do depended on which command
    // minted it. Both go through `self_signed_ca` now; this states the set so
    // a third copy cannot appear quietly.
    #[test]
    fn a_ca_may_sign_certificates_and_crls_and_nothing_else() {
        let ca = self_signed_ca("lab", KeyAlgorithm::EcdsaP256, 3650).unwrap();
        let der = der_of(&ca.cert_pem);
        let (_, cert) = X509Certificate::from_der(&der).expect("cert parses");

        let usage = cert
            .key_usage()
            .expect("key usage parses")
            .expect("key usage present")
            .value;

        assert!(usage.key_cert_sign());
        assert!(usage.crl_sign());
        assert!(usage.digital_signature());
        assert!(!usage.key_encipherment());
        assert!(!usage.key_agreement());
    }

    #[test]
    fn an_intermediate_is_issued_by_the_root_and_cannot_issue_further_cas() {
        let root = self_signed_ca("root", KeyAlgorithm::EcdsaP256, 3650).unwrap();
        let intermediate =
            intermediate_ca(&root, "intermediate", KeyAlgorithm::EcdsaP256, 365).unwrap();

        let der = der_of(&intermediate.cert_pem);
        let (_, cert) = X509Certificate::from_der(&der).expect("cert parses");
        let root_der = der_of(&root.cert_pem);
        let (_, root_cert) = X509Certificate::from_der(&root_der).expect("root parses");

        assert!(cert.is_ca());
        assert_eq!(cert.issuer(), root_cert.subject());
        assert_ne!(cert.subject(), cert.issuer());
        assert!(cert.verify_signature(Some(root_cert.public_key())).is_ok());

        let constraints = cert
            .basic_constraints()
            .expect("basic constraints parse")
            .expect("basic constraints present");
        assert_eq!(constraints.value.path_len_constraint, Some(0));
    }

    #[test]
    fn an_unknown_algorithm_is_refused_rather_than_defaulted() {
        assert!(KeyAlgorithm::parse("rsa-4096").is_err());
    }

    #[test]
    fn every_supported_algorithm_round_trips_through_its_name() {
        for algorithm in [KeyAlgorithm::EcdsaP256, KeyAlgorithm::EcdsaP384] {
            assert_eq!(KeyAlgorithm::parse(algorithm.as_str()).unwrap(), algorithm);
        }
    }

    #[test]
    fn the_rejection_names_the_algorithm_that_was_asked_for() {
        let err = KeyAlgorithm::parse("rsa-4096").unwrap_err().to_string();
        assert!(err.contains("rsa-4096"), "{err}");
    }

    #[test]
    fn a_freshly_minted_ca_expires_about_when_it_was_told_to() {
        let ca = self_signed_ca("expiry test", KeyAlgorithm::EcdsaP256, 365).unwrap();
        let days = days_until_expiry(&ca.cert_pem).expect("a cert we just minted parses");

        // Not exactly 365: minting rounds to whole days and the clock moves.
        assert!((363..=365).contains(&days), "got {days}");
    }

    #[test]
    fn a_short_lived_certificate_reports_days_not_years() {
        let ca = self_signed_ca("short", KeyAlgorithm::EcdsaP256, 2).unwrap();
        assert!(days_until_expiry(&ca.cert_pem).unwrap() <= 2);
    }

    // The old implementation asked GNU `date -d`, which macOS does not have,
    // so it returned None and the check reported no finding. None must mean
    // "this is not a certificate", never "I could not tell".
    #[test]
    fn something_that_is_not_a_certificate_is_the_only_none() {
        assert_eq!(days_until_expiry("not a pem at all"), None);
        assert_eq!(days_until_expiry(""), None);
    }
}

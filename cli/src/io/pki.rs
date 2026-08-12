use anyhow::{Result, bail};
use rcgen::{
    BasicConstraints, CertificateParams, DistinguishedName, DnType, DnValue, IsCa, KeyPair,
    KeyUsagePurpose, PKCS_ECDSA_P256_SHA256, PKCS_ECDSA_P384_SHA384,
};
use time::{Duration, OffsetDateTime};

pub const CERT_KEY: &str = "ca.crt";
pub const KEY_KEY: &str = "ca.key";

#[derive(Debug, Clone)]
pub struct CaPem {
    pub cert_pem: String,
    pub key_pem: String,
}

pub fn key_pair(algorithm: &str) -> Result<KeyPair> {
    match algorithm {
        "ecdsa-p256" => Ok(KeyPair::generate_for(&PKCS_ECDSA_P256_SHA256)?),
        "ecdsa-p384" => Ok(KeyPair::generate_for(&PKCS_ECDSA_P384_SHA384)?),
        other => bail!("unsupported key algorithm: {other}"),
    }
}

pub fn self_signed_ca(cn: &str, algorithm: &str, days: u32) -> Result<CaPem> {
    let key = key_pair(algorithm)?;
    let params = ca_params(cn, days);
    let cert = params.self_signed(&key)?;

    Ok(CaPem {
        cert_pem: cert.pem(),
        key_pem: key.serialize_pem(),
    })
}

pub fn intermediate_ca(root: &CaPem, cn: &str, algorithm: &str, days: u32) -> Result<CaPem> {
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
        let ca = self_signed_ca("Catallaxy Lab CA (mesh.local)", "ecdsa-p256", 3650).unwrap();
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

    #[test]
    fn an_intermediate_is_issued_by_the_root_and_cannot_issue_further_cas() {
        let root = self_signed_ca("root", "ecdsa-p256", 3650).unwrap();
        let intermediate = intermediate_ca(&root, "intermediate", "ecdsa-p256", 365).unwrap();

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
        assert!(self_signed_ca("cn", "rsa-4096", 365).is_err());
    }
}

use std::path::Path;

use crate::verify::{Diagnostic, Severity, VerifyContext, diag};

const CHECK: &str = "certificates";

const WARN_WITHIN_DAYS: i64 = 30;

pub fn run(ctx: &VerifyContext<'_>) -> Vec<Diagnostic> {
    let state = crate::host::state::lab_state_dir(ctx.lab_name);

    let candidates = [
        (
            "lab CA",
            state
                .join(crate::host::state::PROXY_SERVICE)
                .join(crate::host::state::CA_CERT),
        ),
        (
            "lab ingress certificate",
            state
                .join(crate::host::state::PROXY_SERVICE)
                .join("lab.pem"),
        ),
    ];

    candidates
        .iter()
        .filter(|(_, path)| path.exists())
        .filter_map(|(what, path)| classify(what, path, days_until_expiry(path)))
        .collect()
}

fn classify(what: &str, path: &Path, days: Option<i64>) -> Option<Diagnostic> {
    let days = days?;

    if days < 0 {
        return Some(diag(
            Severity::Error,
            CHECK,
            "<host>",
            what,
            format!(
                "expired {} day(s) ago ({}). TLS to this lab fails until it is reissued.",
                -days,
                path.display(),
            ),
        ));
    }

    if days <= WARN_WITHIN_DAYS {
        return Some(diag(
            Severity::Warning,
            CHECK,
            "<host>",
            what,
            format!("expires in {days} day(s) ({})", path.display()),
        ));
    }

    None
}

fn days_until_expiry(path: &Path) -> Option<i64> {
    let pem = crate::io::fs::read_to_string(path).ok()?;
    crate::io::pki::days_until_expiry(&pem)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn path() -> &'static Path {
        Path::new("/tmp/ca.crt")
    }

    #[test]
    fn a_certificate_with_a_year_left_is_silent() {
        assert!(classify("lab CA", path(), Some(365)).is_none());
    }

    #[test]
    fn a_certificate_close_to_expiry_warns() {
        let d = classify("lab CA", path(), Some(7)).expect("should warn");
        assert_eq!(d.severity, Severity::Warning);
        assert!(d.message.contains("expires in 7 day(s)"), "{}", d.message);
    }

    #[test]
    fn an_expired_certificate_is_an_error() {
        let d = classify("lab CA", path(), Some(-3)).expect("should error");
        assert_eq!(d.severity, Severity::Error);
        assert!(d.message.contains("expired 3 day(s) ago"), "{}", d.message);
    }

    #[test]
    fn a_certificate_we_cannot_read_is_not_a_finding() {
        assert!(classify("lab CA", path(), None).is_none());
    }

    #[test]
    fn the_boundary_warns_rather_than_staying_silent() {
        assert!(classify("lab CA", path(), Some(WARN_WITHIN_DAYS)).is_some());
        assert!(classify("lab CA", path(), Some(WARN_WITHIN_DAYS + 1)).is_none());
    }
}

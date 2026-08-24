use anyhow::{Context, Result};

/// An HTTP client that trusts the lab's CA as well as the system roots.
///
/// # Errors
///
/// If the active CA bundle exists but is not PEM, or the client cannot be
/// built. A bundle that cannot be read is a warning and the client is still
/// returned, because the system roots alone are enough for anything outside
/// the lab.
pub fn client(builder: reqwest::ClientBuilder) -> Result<reqwest::Client> {
    let mut builder = builder;
    if let Some(bundle) = super::trust::active_bundle() {
        match std::fs::read(&bundle) {
            Ok(pem) => {
                for cert in reqwest::Certificate::from_pem_bundle(&pem)
                    .with_context(|| format!("parsing CA bundle at {}", bundle.display()))?
                {
                    builder = builder.add_root_certificate(cert);
                }
            }
            Err(e) => {
                eprintln!(
                    "warning: could not read CA bundle {}: {e}",
                    bundle.display()
                );
            }
        }
    }
    builder.build().context("building HTTP client")
}

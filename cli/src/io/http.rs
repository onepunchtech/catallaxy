use anyhow::{Context, Result};

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

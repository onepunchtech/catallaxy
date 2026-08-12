use std::process::Command;
use std::thread::sleep;
use std::time::Duration;

use anyhow::{Result, bail};
use console::style;

use crate::config::Context as CataContext;
use crate::io::process::run_streaming;

const MAX_ATTEMPTS: u32 = 6;

const BACKOFF: Duration = Duration::from_secs(8);

pub fn deploy(
    ctx: &CataContext,
    kube_context: &str,
    app_name: &str,
    manifests_dir: &str,
    timeout: &str,
) -> Result<()> {
    let prefixed_app_name = format!("cata-{}", app_name);

    let mut last_err: Option<anyhow::Error> = None;
    for attempt in 1..=MAX_ATTEMPTS {
        let mut cmd = Command::new("kapp");
        cmd.args([
            "deploy",
            "--kubeconfig-context",
            kube_context,
            "--app",
            &prefixed_app_name,
            "--namespace",
            "default",
            "--file",
            manifests_dir,
            "--yes",
            "--wait",
            "--wait-check-interval",
            "5s",
            "--wait-timeout",
            timeout,
        ]);

        match run_streaming(&mut cmd, ctx) {
            Ok(()) => return Ok(()),
            Err(e) => {
                if attempt == MAX_ATTEMPTS {
                    last_err = Some(e);
                    break;
                }
                println!(
                    "{} kapp deploy of '{app_name}' failed (attempt {attempt}/{MAX_ATTEMPTS}); \
                     sleeping {backoff}s and retrying — kapp is idempotent, only missing \
                     resources will be re-applied. Common cause on fresh DOKS clusters: \
                     API-server front-end returning 'unexpected EOF' mid-batch. See \
                     kapp output above.",
                    style(">>>").yellow(),
                    backoff = BACKOFF.as_secs(),
                );
                sleep(BACKOFF);
            }
        }
    }

    bail!(
        "kapp deploy of '{app_name}' failed after {MAX_ATTEMPTS} attempts. Last error: {}",
        last_err.map(|e| e.to_string()).unwrap_or_default(),
    );
}

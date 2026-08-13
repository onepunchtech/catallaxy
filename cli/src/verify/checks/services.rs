use crate::host::services::probe_once;
use crate::io;
use crate::verify::{Diagnostic, Severity, VerifyContext, diag};

const CHECK: &str = "services";

pub fn run(ctx: &VerifyContext<'_>) -> Vec<Diagnostic> {
    let mut diags = Vec::new();

    for (name, svc) in &ctx.lab.services {
        let container = svc.container.as_str();
        if !io::docker::container_running(container) {
            diags.push(diag(
                Severity::Error,
                CHECK,
                "<host>",
                name,
                format!("container '{container}' is not running"),
            ));
            continue;
        }

        let Some(probe) = svc.ready_probe.as_ref() else {
            continue;
        };
        let host = probe.host.as_str();
        let port = probe.port;
        let path = probe.path.as_deref().unwrap_or("/");
        let expected = u64::from(probe.expected_status.unwrap_or(200));

        if let Err(e) = probe_once(&format!("{host}:{port}"), &probe.kind, host, path, expected) {
            diags.push(diag(
                Severity::Error,
                CHECK,
                "<host>",
                name,
                format!("container is up but its readyProbe fails: {e}"),
            ));
        }
    }
    diags
}

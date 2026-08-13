use crate::commands::lab::services::probe_once;
use crate::io;
use crate::verify::{Diagnostic, Severity, VerifyContext, diag};

const CHECK: &str = "services";

pub fn run(ctx: &VerifyContext<'_>) -> Vec<Diagnostic> {
    let mut diags = Vec::new();

    for (name, svc) in &ctx.lab.services {
        let container = svc["container"].as_str().unwrap_or(name);
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

        let Some(probe) = svc.get("readyProbe").filter(|p| !p.is_null()) else {
            continue;
        };
        let kind = probe["kind"].as_str().unwrap_or("tcp");
        let host = probe["host"].as_str().unwrap_or("127.0.0.1");
        let Some(port) = probe["port"].as_u64() else {
            continue;
        };
        let path = probe["path"].as_str().unwrap_or("/");
        let expected = probe["expectedStatus"].as_u64().unwrap_or(200);

        if let Err(e) = probe_once(&format!("{host}:{port}"), kind, host, path, expected) {
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

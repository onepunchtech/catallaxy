use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::time::Duration;

use crate::io;
use crate::verify::{Diagnostic, Severity, VerifyContext, diag};

const CHECK: &str = "endpoints";

/// Whether a status means the route resolved and something answered.
///
/// Anything under 400 did. So did 401 and 403: a route that resolved and then
/// declined the request has proven what this check asks. A 404 has not, and
/// 404 is exactly what a gateway returns when no route matched, which is the
/// failure this check exists to catch.
pub(crate) fn answered(status: u16) -> bool {
    status < 400 || status == 401 || status == 403
}

/// Probes every public host the lab routes, through the lab's own ingress and
/// its own CA. This is the check the other four cannot stand in for: routing
/// by hostname, TLS against the lab CA, and the workload actually answering
/// are three things no amount of eval or lint can exercise.
///
/// Each host is pinned to the proxy's published address rather than looked up,
/// so this works whether or not `lab.dns.configureHost` pointed the machine's
/// resolver at the lab. Nothing here needs `sudo` or a modified host.
pub async fn run(ctx: &VerifyContext<'_>) -> Vec<Diagnostic> {
    if !ctx.config.endpoints.enable {
        return Vec::new();
    }

    let hosts: Vec<(String, _)> = ctx
        .exposed_hosts()
        .into_iter()
        .filter(|(_, h)| h.tier == "public")
        .collect();
    if hosts.is_empty() {
        return Vec::new();
    }

    let Some((scheme, port)) = ctx.ingress() else {
        return vec![diag(
            Severity::Error,
            CHECK,
            "<host>",
            "proxy",
            format!(
                "{} host(s) are routed but the lab publishes no ingress port to reach them on",
                hosts.len()
            ),
        )];
    };

    let ingress = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port);
    let mut builder = reqwest::Client::builder()
        .timeout(Duration::from_secs(15))
        .redirect(reqwest::redirect::Policy::none());
    for (_, host) in &hosts {
        builder = builder.resolve(&host.host, ingress);
    }

    let client = match io::http::client(builder) {
        Ok(c) => c,
        Err(e) => {
            return vec![diag(
                Severity::Error,
                CHECK,
                "<host>",
                "http-client",
                format!("could not build an HTTP client: {e}"),
            )];
        }
    };

    let accepted = &ctx.config.endpoints.accept_statuses;
    let mut diags = Vec::new();

    for (cluster, host) in hosts {
        let url = format!("{scheme}://{}/", host.host);
        match client.get(&url).send().await {
            Err(e) => diags.push(diag(
                Severity::Error,
                CHECK,
                &cluster,
                &host.host,
                format!(
                    "{url} did not answer, routed by bundle '{}': {e}",
                    host.bundle
                ),
            )),
            Ok(response) => {
                let status = response.status().as_u16();
                if !answered(status) && !accepted.contains(&status) {
                    diags.push(diag(
                        Severity::Error,
                        CHECK,
                        &cluster,
                        &host.host,
                        format!("{url} answered {status}"),
                    ));
                }
            }
        }
    }
    diags
}

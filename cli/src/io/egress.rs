//! Reaching lab hostnames from the host, without touching the host.
//!
//! A lab's zone resolves through the lab's own DNS, which nothing on this
//! machine consults unless someone edits `/etc/resolv.conf` with `sudo`. So
//! `git clone https://git.<zone>/...` failed on a machine that had not opted
//! into that, and `lab.dns.configureHost` existed to make it not fail.
//!
//! The lab runs a forward proxy inside its own docker network instead, where
//! the zone resolves the way it does for anything else in the lab. Pointing a
//! tool at that proxy is an environment variable, which is this module, and
//! the same seam already hands out `KUBECONFIG` and the lab's CA bundle.
//!
//! Loopback is excluded on purpose: the API server, the registry and every
//! other published port are reached directly, and sending them through the
//! proxy would be a slower path to the same place.

use std::ffi::OsString;
use std::process::Command;
use std::sync::{OnceLock, RwLock};

fn active() -> &'static RwLock<Option<String>> {
    static ACTIVE: OnceLock<RwLock<Option<String>>> = OnceLock::new();
    ACTIVE.get_or_init(|| RwLock::new(None))
}

/// Point every tool this process spawns at the lab's proxy.
pub fn activate(port: u16) {
    let mut guard = active().write().expect("egress state lock poisoned");
    *guard = Some(format!("http://127.0.0.1:{port}"));
}

/// Read the proxy's published port off the lab, if it runs one.
///
/// A lab with no ingress runs no proxy, and nothing changes for it.
pub fn activate_from(lab: &crate::domain::lab::LabSpec) {
    let Some(service) = lab.services.get("egress") else {
        return;
    };
    let Some(port) = service
        .ports
        .first()
        .and_then(|m| crate::domain::port_mapping::host_port_of(m))
    else {
        return;
    };
    activate(port);
}

pub fn active_proxy() -> Option<String> {
    let guard = active().read().expect("egress state lock poisoned");
    guard.clone()
}

/// What must never be reached through the proxy.
///
/// Every address a lab publishes to the host is local, and an in-cluster name
/// should not be tunnelled out through the host. Which entries are
/// load-bearing rather than defensive is asserted in `loopback_is_never_proxied`.
const DIRECT: &str = "127.0.0.1,0.0.0.0,localhost,::1,.svc,.cluster.local,host.k3d.internal";

pub fn env_pairs(proxy: &str) -> Vec<(&'static str, OsString)> {
    let p = OsString::from(proxy);
    vec![
        ("HTTP_PROXY", p.clone()),
        ("http_proxy", p.clone()),
        ("HTTPS_PROXY", p.clone()),
        ("https_proxy", p),
        ("NO_PROXY", OsString::from(DIRECT)),
        ("no_proxy", OsString::from(DIRECT)),
    ]
}

pub fn apply(cmd: &mut Command) {
    let Some(proxy) = active_proxy() else {
        return;
    };
    for (k, v) in env_pairs(&proxy) {
        cmd.env(k, v);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Both spellings, because curl reads the lowercase ones and most
    /// everything else reads the uppercase ones, and a tool that sees only
    /// half of the pair proxies what it should not or vice versa.
    #[test]
    fn both_spellings_are_set() {
        let names: Vec<&str> = env_pairs("http://127.0.0.1:3128")
            .iter()
            .map(|(k, _)| *k)
            .collect();
        for expected in [
            "HTTP_PROXY",
            "http_proxy",
            "HTTPS_PROXY",
            "https_proxy",
            "NO_PROXY",
            "no_proxy",
        ] {
            assert!(names.contains(&expected), "{expected} missing");
        }
    }

    #[test]
    fn the_published_port_is_read_from_the_mapping() {
        assert_eq!(
            crate::domain::port_mapping::host_port_of("127.0.0.1:3128:8888"),
            Some(3128)
        );
        assert_eq!(
            crate::domain::port_mapping::host_port_of("3128:8888"),
            Some(3128)
        );
        assert_eq!(crate::domain::port_mapping::host_port_of("8888"), None);
    }

    /// The kubeconfig points every cluster at 127.0.0.1, so proxying loopback
    /// would send every API call on a detour through a container.
    #[test]
    fn loopback_is_never_proxied() {
        let pairs = env_pairs("http://127.0.0.1:3128");
        let (_, no_proxy) = pairs.iter().find(|(k, _)| *k == "NO_PROXY").unwrap();
        let value = no_proxy.to_string_lossy();
        assert!(value.contains("127.0.0.1"));
        assert!(value.contains("localhost"));
        // k3d writes the API server as https://0.0.0.0:<port>, so this one is
        // load-bearing rather than defensive.
        assert!(value.contains("0.0.0.0"));
    }
}

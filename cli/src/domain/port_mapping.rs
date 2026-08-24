//! Docker port publishing, parsed once.
//!
//! Four call sites read the same `[ip:]host:container[/proto][@node]` string
//! and disagreed about it. Two were named `published_port` and returned
//! different types; two forgot a suffix and mis-read the host port. The
//! address half decides whether two labs contend and whether this machine can
//! reach the publish at all, and that judgement was inlined three times.

use std::fmt;

/// One `-p` argument: which address, which host port, which container port.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PortMapping<'a> {
    /// The bind address, absent when docker was given none and binds all.
    pub addr: Option<&'a str>,
    pub host: u16,
    pub container: u16,
}

/// Addresses that more than one lab can be listening on.
///
/// A lab's own bridge gateway is not among them: `lab-subnets` keeps those
/// distinct, so `172.23.0.1:80` and `172.24.0.1:80` are different sockets.
const SHARED: [&str; 5] = ["0.0.0.0", "127.0.0.1", "::", "::1", "[::1]"];

/// Whether a bind address is one several labs could be using.
///
/// `None` means every interface, which contends with everything.
#[must_use]
pub fn address_is_shared(addr: Option<&str>) -> bool {
    addr.is_none_or(|a| SHARED.contains(&a))
}

impl<'a> PortMapping<'a> {
    /// Parses a docker publish argument, or `None` if it is not one.
    ///
    /// Tolerates the `/proto` docker appends and the `@server:0` node
    /// selector k3d appends, both of which add colons that would otherwise be
    /// counted as fields.
    #[must_use]
    pub fn parse(mapping: &'a str) -> Option<Self> {
        let head = mapping.split('@').next()?.split('/').next()?;
        let fields: Vec<&str> = head.split(':').collect();
        let (addr, host, container) = match fields.as_slice() {
            [host, container] => (None, *host, *container),
            [addr, host, container] => (Some(*addr), *host, *container),
            _ => return None,
        };
        Some(PortMapping {
            addr,
            host: host.parse().ok()?,
            container: container.parse().ok()?,
        })
    }

    /// Whether this machine can reach the publish.
    ///
    /// A lab's gateway-bound publish is for pods and containers inside the
    /// lab; nothing on the host dials it.
    #[must_use]
    pub fn is_host_reachable(&self) -> bool {
        address_is_shared(self.addr)
    }
}

/// Whether two labs could fight over this publish.
///
/// An unparseable mapping answers yes: the preflight this feeds exists to say
/// nothing was started, and guessing that an unreadable publish is private
/// would skip it.
#[must_use]
pub fn contends_across_labs(mapping: &str) -> bool {
    PortMapping::parse(mapping).is_none_or(|m| address_is_shared(m.addr))
}

/// The host port of a docker publish argument.
#[must_use]
pub fn host_port_of(mapping: &str) -> Option<u16> {
    PortMapping::parse(mapping).map(|m| m.host)
}

impl fmt::Display for PortMapping<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.addr {
            Some(addr) => write!(f, "{addr}:{}:{}", self.host, self.container),
            None => write!(f, "{}:{}", self.host, self.container),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every shape the repo actually produces, in one place, because the four
    /// parsers this replaces each handled a different subset and the gaps
    /// were only visible by reading them side by side.
    #[test]
    fn every_shape_the_repo_produces_parses() {
        let cases: [(&str, Option<&str>, u16, u16); 7] = [
            ("5054:5000", None, 5054, 5000),
            ("5359:53/udp", None, 5359, 53),
            ("5359:53/tcp", None, 5359, 53),
            ("127.0.0.1:8083:80", Some("127.0.0.1"), 8083, 80),
            ("172.23.0.1:80:80", Some("172.23.0.1"), 80, 80),
            ("127.0.0.1:3132:8888", Some("127.0.0.1"), 3132, 8888),
            ("8080:80@server:0", None, 8080, 80),
        ];
        for (raw, addr, host, container) in cases {
            let got = PortMapping::parse(raw).unwrap_or_else(|| panic!("{raw} did not parse"));
            assert_eq!(got.addr, addr, "{raw}");
            assert_eq!(got.host, host, "{raw}");
            assert_eq!(got.container, container, "{raw}");
        }
    }

    /// The two suffixes are why this is one function. `io::egress` stripped
    /// neither and `verify` stripped only the protocol, so a k3d mapping read
    /// as a port of `0` or not at all.
    #[test]
    fn both_suffixes_come_off() {
        assert_eq!(host_port_of("8080:80@server:0"), Some(8080));
        assert_eq!(host_port_of("127.0.0.1:5359:53/udp"), Some(5359));
        assert_eq!(
            PortMapping::parse("127.0.0.1:8083:80@agent:1").map(|m| m.container),
            Some(80)
        );
    }

    /// Two labs on loopback collide; two labs on their own bridge gateways do
    /// not. Comparing bare port numbers said one lab's `172.25.0.1:80` was
    /// taken by another's `127.0.0.1:80` and refused to start it.
    #[test]
    fn only_a_shared_address_contends() {
        assert!(contends_across_labs("8083:80"));
        assert!(contends_across_labs("127.0.0.1:8083:80"));
        assert!(contends_across_labs("0.0.0.0:8083:80"));
        assert!(!contends_across_labs("172.23.0.1:80:80"));
        assert!(!contends_across_labs("172.24.0.1:443:443"));
    }

    #[test]
    fn an_unreadable_mapping_is_assumed_to_contend() {
        assert!(contends_across_labs("nonsense"));
        assert!(contends_across_labs(""));
        assert_eq!(host_port_of("nonsense"), None);
        assert_eq!(host_port_of("8888"), None);
    }

    #[test]
    fn a_gateway_publish_is_not_reachable_from_here() {
        let gateway = PortMapping::parse("172.23.0.1:80:80").unwrap();
        assert!(!gateway.is_host_reachable());
        let loopback = PortMapping::parse("127.0.0.1:8083:80").unwrap();
        assert!(loopback.is_host_reachable());
        let every = PortMapping::parse("5054:5000").unwrap();
        assert!(every.is_host_reachable());
    }

    #[test]
    fn ipv6_forms_count_as_shared() {
        assert!(address_is_shared(Some("::")));
        assert!(address_is_shared(Some("[::1]")));
        assert!(!address_is_shared(Some("172.23.0.1")));
    }
}

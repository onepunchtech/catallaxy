use std::net::Ipv4Addr;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cidr {
    base: u32,
    prefix: u8,
}

impl Cidr {
    pub fn parse(text: &str) -> Option<Self> {
        let (addr, prefix) = text.trim().split_once('/')?;
        let addr: Ipv4Addr = addr.parse().ok()?;
        let prefix: u8 = prefix.parse().ok()?;
        if prefix > 32 {
            return None;
        }
        Some(Cidr {
            base: u32::from(addr) & mask(prefix),
            prefix,
        })
    }

    pub fn overlaps(&self, other: &Cidr) -> bool {
        let shared = mask(self.prefix.min(other.prefix));
        self.base & shared == other.base & shared
    }
}

impl std::fmt::Display for Cidr {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}/{}", Ipv4Addr::from(self.base), self.prefix)
    }
}

fn mask(prefix: u8) -> u32 {
    if prefix == 0 {
        0
    } else {
        u32::MAX << (32 - prefix)
    }
}

pub fn colliding<'a>(subnet: &str, taken: &'a [String]) -> Vec<&'a str> {
    let Some(ours) = Cidr::parse(subnet) else {
        return Vec::new();
    };

    taken
        .iter()
        .filter(|t| Cidr::parse(t).is_some_and(|other| ours.overlaps(&other)))
        .map(String::as_str)
        .collect()
}

pub fn first_free_16(taken: &[String]) -> Option<String> {
    let parsed: Vec<Cidr> = taken.iter().filter_map(|t| Cidr::parse(t)).collect();

    (16..=31)
        .map(|second| format!("172.{second}.0.0/16"))
        .find(|candidate| {
            Cidr::parse(candidate).is_some_and(|c| !parsed.iter().any(|taken| c.overlaps(taken)))
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn owned(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn identical_ranges_overlap() {
        let a = Cidr::parse("172.20.0.0/16").expect("parses");
        assert!(a.overlaps(&a));
    }

    #[test]
    fn distinct_sixteens_do_not_overlap() {
        let a = Cidr::parse("172.20.0.0/16").expect("parses");
        let b = Cidr::parse("172.21.0.0/16").expect("parses");
        assert!(!a.overlaps(&b));
        assert!(!b.overlaps(&a));
    }

    #[test]
    fn a_range_inside_another_overlaps_both_ways() {
        let wide = Cidr::parse("172.16.0.0/12").expect("parses");
        let narrow = Cidr::parse("172.20.0.0/16").expect("parses");
        assert!(wide.overlaps(&narrow));
        assert!(narrow.overlaps(&wide));
    }

    #[test]
    fn a_host_bit_outside_the_prefix_is_ignored() {
        assert_eq!(
            Cidr::parse("172.20.5.9/16"),
            Cidr::parse("172.20.0.0/16"),
            "a CIDR is its network, so the host bits must not change identity"
        );
    }

    #[test]
    fn nonsense_parses_to_nothing_rather_than_panicking() {
        for bad in ["", "172.20.0.0", "172.20.0.0/33", "not/16", "172.20.0.0/x"] {
            assert!(Cidr::parse(bad).is_none(), "{bad}");
        }
    }

    #[test]
    fn only_the_networks_that_actually_collide_are_reported() {
        let taken = owned(&["172.17.0.0/16", "172.20.0.0/16", "10.0.0.0/8"]);

        assert_eq!(colliding("172.20.0.0/16", &taken), vec!["172.20.0.0/16"]);
        assert!(colliding("172.25.0.0/16", &taken).is_empty());
        assert_eq!(colliding("10.1.2.0/24", &taken), vec!["10.0.0.0/8"]);
    }

    #[test]
    fn a_free_sixteen_skips_everything_taken() {
        let taken = owned(&["172.16.0.0/16", "172.17.0.0/16", "172.18.0.0/16"]);
        assert_eq!(first_free_16(&taken), Some("172.19.0.0/16".to_string()));
    }

    #[test]
    fn a_wide_range_rules_out_everything_it_covers() {
        let taken = owned(&["172.16.0.0/12"]);
        assert_eq!(
            first_free_16(&taken),
            None,
            "172.16/12 covers 172.16 through 172.31, so no /16 there is free"
        );
    }
}

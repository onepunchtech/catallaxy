//! Which lab a container belongs to, recorded on the container itself.
//!
//! Containers used to carry nothing. A `catallaxy-<lab>-ingress` could be
//! guessed at by name, but a lab name contains dashes so the guess is a
//! heuristic, and nothing at all recorded the flake that created it. That is
//! why a lab left running by a failed `lab up` could not be found, and why a
//! lab the flake no longer defines could not be removed: `lab destroy` reads
//! the teardown plan out of the flake, so it can only take down what the flake
//! still describes.
//!
//! The label namespace is the one the rest of the repo already uses for its
//! own annotations.

/// The lab a container belongs to.
pub const LAB: &str = "catallaxy.io/lab";

/// The flake URI the lab was run from. Recorded so an orphan can say where it
/// came from; never compared, because one lab legitimately runs from two
/// checkouts and enforcing it would recreate the container on every alternate
/// run.
pub const FLAKE: &str = "catallaxy.io/flake";

/// Which host service this is, as the lab names it.
pub const SERVICE: &str = "catallaxy.io/service";

/// Which bundle rendered a Kubernetes resource.
///
/// The two labels above ride on containers; these two ride on every rendered
/// manifest, stamped in `lib/render/manifest.nix`. `lab up` asks the cluster
/// for resources carrying LAB, and BUNDLE is what says whether the
/// declaration still names the thing that created them.
pub const BUNDLE: &str = "catallaxy.io/bundle";

/// One cheap `docker ps --filter` selector for everything catallaxy made.
pub const MANAGED_BY: &str = "catallaxy.io/managed-by";
pub const MANAGED_BY_VALUE: &str = "catallaxy";

/// Bumped if these keys ever change meaning, so an old container reads as
/// unrecognised rather than being misread.
pub const SCHEMA: &str = "catallaxy.io/schema";
pub const SCHEMA_VERSION: &str = "1";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Provenance {
    pub lab: String,
    pub flake: String,
}

impl Provenance {
    pub fn new(lab: impl Into<String>, flake: impl Into<String>) -> Self {
        Provenance {
            lab: lab.into(),
            flake: flake.into(),
        }
    }

    pub fn labels(&self, service: &str) -> Vec<(String, String)> {
        vec![
            (MANAGED_BY.to_string(), MANAGED_BY_VALUE.to_string()),
            (SCHEMA.to_string(), SCHEMA_VERSION.to_string()),
            (LAB.to_string(), self.lab.clone()),
            (FLAKE.to_string(), self.flake.clone()),
            (SERVICE.to_string(), service.to_string()),
        ]
    }
}

/// The lab a set of container labels names, if they name one.
pub fn lab_of(labels: &std::collections::BTreeMap<String, String>) -> Option<&str> {
    labels
        .get(LAB)
        .map(String::as_str)
        .filter(|l| !l.is_empty())
}

pub fn flake_of(labels: &std::collections::BTreeMap<String, String>) -> Option<&str> {
    labels
        .get(FLAKE)
        .map(String::as_str)
        .filter(|f| !f.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn as_map(pairs: Vec<(String, String)>) -> BTreeMap<String, String> {
        pairs.into_iter().collect()
    }

    #[test]
    fn every_container_says_which_lab_and_flake_made_it() {
        let labels = as_map(Provenance::new("home-lab", "/src/labs#home-lab").labels("ingress"));
        assert_eq!(lab_of(&labels), Some("home-lab"));
        assert_eq!(flake_of(&labels), Some("/src/labs#home-lab"));
        assert_eq!(labels.get(SERVICE).map(String::as_str), Some("ingress"));
    }

    #[test]
    fn everything_catallaxy_made_is_selectable_by_one_label() {
        let labels = as_map(Provenance::new("l", "f").labels("dns"));
        assert_eq!(
            labels.get(MANAGED_BY).map(String::as_str),
            Some(MANAGED_BY_VALUE)
        );
    }

    #[test]
    fn a_container_from_before_labels_names_no_lab() {
        assert_eq!(lab_of(&BTreeMap::new()), None);
        assert_eq!(flake_of(&BTreeMap::new()), None);
    }

    #[test]
    fn an_empty_label_is_not_a_lab_name() {
        let labels = as_map(vec![(LAB.to_string(), String::new())]);
        assert_eq!(lab_of(&labels), None);
    }

    #[test]
    fn a_lab_name_with_dashes_survives_the_round_trip() {
        let labels = as_map(Provenance::new("home-lab-two", "f").labels("registry"));
        assert_eq!(lab_of(&labels), Some("home-lab-two"));
    }
}

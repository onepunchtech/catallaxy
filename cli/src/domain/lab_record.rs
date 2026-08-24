//! What a lab put on this machine, written where the flake is not needed to
//! read it.
//!
//! `lab destroy` reads the teardown plan out of the flake, so it can only take
//! down a lab the flake still defines. A lab deleted, renamed, or built from
//! another checkout is unrecoverable through it. This record is the local
//! evidence `lab cleanup` works from instead.
//!
//! It is written before the first step runs, so a `lab up` that dies partway
//! has still left a complete one. That is what makes leaving a failed run in
//! place safe rather than careless.
//!
//! It also carries the k3d cluster name, which nothing else records. The
//! logical cluster name and the k3d one differ by `lab.contextPrefix`, which
//! lowercases and collapses four characters to `-` before joining with an
//! unescaped `-`. Lab `home-lab` cluster `core` and lab `home` cluster
//! `lab-core` produce the same k3d name, so the mapping cannot be inverted and
//! has to be written down.

use serde::{Deserialize, Serialize};

use super::lab::LabSpec;

/// Bumped when a field stops meaning what it did, so an older record reads as
/// absent rather than being misread.
pub const SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceRecord {
    pub key: String,
    pub container: String,
    pub ports: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClusterRecord {
    pub cluster: String,
    pub provisioner: String,
    /// The name k3d knows it by, which is what `k3d cluster delete` needs.
    pub k3d_cluster: Option<String>,
    pub kube_context: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LabRecord {
    pub schema_version: u32,
    pub lab: String,
    pub flake: String,
    pub network: String,
    pub docker_subnet: String,
    pub dns_zone: Option<String>,
    pub services: Vec<ServiceRecord>,
    pub clusters: Vec<ClusterRecord>,
}

impl LabRecord {
    pub fn of(lab: &LabSpec, flake: &str) -> Self {
        LabRecord {
            schema_version: SCHEMA_VERSION,
            lab: lab.lab_name.clone(),
            flake: flake.to_string(),
            network: lab.network.name.clone(),
            docker_subnet: lab.network.docker_subnet.clone(),
            dns_zone: lab.dns_info.as_ref().map(|d| d.zone.clone()),
            services: lab
                .services
                .iter()
                .map(|(key, svc)| ServiceRecord {
                    key: key.clone(),
                    container: svc.container.clone(),
                    ports: svc.ports.clone(),
                })
                .collect(),
            clusters: lab
                .cluster_names
                .iter()
                .filter_map(|name| {
                    let spec = lab.clusters.get(name)?;
                    Some(ClusterRecord {
                        cluster: name.clone(),
                        provisioner: format!("{:?}", spec.provisioner).to_lowercase(),
                        k3d_cluster: Some(spec.provisioner_config.k3d.cluster_name.clone())
                            .filter(|n| !n.is_empty()),
                        kube_context: spec.kube_context.clone(),
                    })
                })
                .collect(),
        }
    }

    /// Every container name this lab is responsible for.
    pub fn container_names(&self) -> Vec<&str> {
        self.services
            .iter()
            .map(|s| s.container.as_str())
            .filter(|c| !c.is_empty())
            .collect()
    }

    pub fn k3d_cluster_names(&self) -> Vec<&str> {
        self.clusters
            .iter()
            .filter_map(|c| c.k3d_cluster.as_deref())
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record() -> LabRecord {
        LabRecord {
            schema_version: SCHEMA_VERSION,
            lab: "home-lab".into(),
            flake: "/src/labs#home-lab".into(),
            network: "home-lab".into(),
            docker_subnet: "172.30.0.0/16".into(),
            dns_zone: Some("home.test".into()),
            services: vec![ServiceRecord {
                key: "proxy".into(),
                container: "catallaxy-home-lab-ingress".into(),
                ports: vec!["80:80".into()],
            }],
            clusters: vec![ClusterRecord {
                cluster: "core".into(),
                provisioner: "k3d".into(),
                k3d_cluster: Some("home-lab-core".into()),
                kube_context: "k3d-home-lab-core".into(),
            }],
        }
    }

    #[test]
    fn a_record_round_trips_through_json() {
        let json = serde_json::to_string(&record()).unwrap();
        assert_eq!(serde_json::from_str::<LabRecord>(&json).unwrap(), record());
    }

    // The k3d name cannot be derived back from the logical one, so it is the
    // reason this record exists at all.
    #[test]
    fn it_carries_the_k3d_name_that_cannot_be_derived() {
        assert_eq!(record().k3d_cluster_names(), vec!["home-lab-core"]);
    }

    #[test]
    fn it_names_every_container_the_lab_is_responsible_for() {
        assert_eq!(
            record().container_names(),
            vec!["catallaxy-home-lab-ingress"]
        );
    }

    #[test]
    fn a_service_with_no_container_is_not_something_to_remove() {
        let mut r = record();
        r.services[0].container = String::new();
        assert!(r.container_names().is_empty());
    }

    #[test]
    fn a_cluster_with_no_k3d_name_is_not_something_to_delete() {
        let mut r = record();
        r.clusters[0].k3d_cluster = None;
        assert!(r.k3d_cluster_names().is_empty());
    }
}

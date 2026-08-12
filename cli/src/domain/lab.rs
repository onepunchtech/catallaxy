use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::cluster::ClusterSpec;
use super::plan::PlannedStep;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LabSpec {
    #[serde(default)]
    pub lab_name: String,

    #[serde(default)]
    pub environment: Option<String>,

    #[serde(default)]
    pub cluster_names: Vec<String>,

    #[serde(default)]
    pub clusters: BTreeMap<String, ClusterSpec>,

    #[serde(default)]
    pub network: NetworkInfo,

    #[serde(default)]
    pub dns_info: Option<DnsInfo>,

    #[serde(default)]
    pub registry_port: Option<u16>,

    #[serde(default)]
    pub registry_upstreams: Vec<String>,

    #[serde(default)]
    pub cd: CdConfig,

    #[serde(default)]
    pub secrets: LabSecrets,

    #[serde(default)]
    pub deployment_plan: Vec<PlannedStep>,

    #[serde(default)]
    pub teardown_plan: Vec<PlannedStep>,

    #[serde(default)]
    pub runtime_contexts: BTreeMap<String, String>,

    #[serde(default)]
    pub services: Value,

    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NetworkInfo {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub docker_subnet: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DnsInfo {
    pub host: String,
    pub port: u16,
    pub zone: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CdConfig {
    #[serde(default = "default_cd_strategy")]
    pub strategy: String,
    #[serde(default)]
    pub git: Value,
}

fn default_cd_strategy() -> String {
    "kapp".to_string()
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LabSecrets {
    #[serde(default)]
    pub stores: Value,
    #[serde(default)]
    pub managed: Value,
    #[serde(default)]
    pub host_projections: Value,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RegistryInfo {
    pub port: u16,
    pub upstreams: Vec<String>,
}

impl LabSpec {
    pub fn from_value(value: Value) -> Result<Self, serde_json::Error> {
        serde_json::from_value(value)
    }
}

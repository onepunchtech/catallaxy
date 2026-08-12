use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClusterSpec {
    #[serde(default)]
    pub name: String,

    #[serde(default)]
    pub lab_name: String,

    #[serde(default)]
    pub provisioner: ProvisionerKind,

    #[serde(default)]
    pub kube_context: Option<String>,

    #[serde(default)]
    pub provisioner_config: Value,

    #[serde(default)]
    pub components: BTreeMap<String, ComponentSpec>,

    #[serde(default)]
    pub projections: Value,

    #[serde(default)]
    pub deploy: Value,

    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum ProvisionerKind {
    K3d,
    Talos,
    Crossplane,
    Capi,
    #[default]
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ComponentSpec {
    #[serde(default)]
    pub enable: bool,

    #[serde(default)]
    pub namespace: Option<String>,

    #[serde(default)]
    pub version: Option<String>,

    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

impl ClusterSpec {
    pub fn from_value(value: Value) -> Result<Self, serde_json::Error> {
        serde_json::from_value(value)
    }

    pub fn deploy_strategy(&self) -> Option<&str> {
        self.deploy.pointer("/strategy").and_then(Value::as_str)
    }

    pub fn k3d_cluster_name(&self) -> Option<&str> {
        self.provisioner_config
            .pointer("/k3d/clusterName")
            .and_then(Value::as_str)
    }
}

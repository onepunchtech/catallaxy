pub mod extract;
pub mod render;

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LabTopology {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub zone: Option<String>,
    pub cd_strategy: String,
    pub network: LabNetwork,
    pub services: BTreeMap<String, LabService>,
    pub clusters: BTreeMap<String, ClusterTopology>,
    pub edges: Vec<TopologyEdge>,
    pub deployment_plan: Vec<PlanStep>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LabNetwork {
    pub name: String,
    pub docker_subnet: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LabService {
    pub description: String,
    pub container: String,
    pub ports: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub running: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClusterTopology {
    pub name: String,
    pub provider: String,
    pub kube_context: String,
    pub control_planes: u64,
    pub workers: u64,
    pub pod_subnet: String,
    pub service_subnet: String,
    pub components: BTreeMap<String, ComponentSummary>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub live: Option<ClusterLiveState>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ComponentSummary {
    pub enabled: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    pub namespace: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub domain: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub health: Option<ComponentHealthState>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "status")]
pub enum ComponentHealthState {
    #[serde(rename = "healthy")]
    Healthy { pod_count: usize },
    #[serde(rename = "degraded")]
    Degraded { ready: usize, total: usize },
    #[serde(rename = "no_pods")]
    NoPods,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClusterLiveState {
    pub reachable: bool,
    pub nodes: Vec<NodeSummary>,
    pub kapp_apps: Vec<KappAppSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NodeSummary {
    pub name: String,
    pub ready: bool,
    pub version: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KappAppSummary {
    pub name: String,
    pub status: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub age: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TopologyEdge {
    pub kind: EdgeKind,
    pub source: String,
    pub target: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EdgeKind {
    ProxyRoute,
    SecretCopy,
    DeployDependency,
    Provisions,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlanStep {
    pub step_type: String,
    pub description: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
}

pub enum TopologyFormat {
    Json,
    Table,
    Mermaid,
    Dot,
}

impl std::str::FromStr for TopologyFormat {
    type Err = std::convert::Infallible;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(match s {
            "json" => Self::Json,
            "mermaid" => Self::Mermaid,
            "dot" => Self::Dot,
            _ => Self::Table,
        })
    }
}

use std::collections::{HashMap, HashSet};

use crate::domain::diagnostic::Diagnostic;
use crate::domain::plan::PlannedStep;

use super::manifest::K8sResource;
use super::{ClusterMetadata, ImagePolicy, LabMetadata};

pub mod assertions;
pub mod crd_schema;
pub mod identity;
pub mod image_pin;
pub mod missing_crd;
pub mod network_policy;
pub mod plan;
pub mod prefix;
pub mod ready_probe;
pub mod references;
pub mod schema;
pub mod selector;

pub struct CheckContext<'a> {
    pub resources: &'a [K8sResource],
    pub cluster: &'a str,
    pub wave_meta: Option<&'a crate::io::ssa::WaveMeta>,
    pub prefix: &'a str,
    pub lab_namespaces: &'a [String],
    pub projection_names: &'a HashSet<String>,
    pub cluster_meta: Option<&'a ClusterMetadata>,
    pub images: &'a ImagePolicy,
}

pub trait CheckRule {
    fn name(&self) -> &'static str;

    fn check(&self, ctx: &CheckContext<'_>) -> Vec<Diagnostic>;
}

pub fn cluster_rules() -> Vec<Box<dyn CheckRule>> {
    vec![
        Box::new(schema::Schema),
        Box::new(identity::Identity),
        Box::new(prefix::Prefix),
        Box::new(selector::Selector),
        Box::new(references::References),
        Box::new(image_pin::ImagePin),
        Box::new(crd_schema::CrdSchema),
        Box::new(missing_crd::MissingCrd),
        Box::new(ready_probe::ReadyProbeTargets),
        Box::new(network_policy::NetworkPolicies),
        Box::new(assertions::Assertions),
    ]
}

pub struct LabCheckContext<'a> {
    pub metadata: &'a LabMetadata,
    pub resources_by_cluster: &'a HashMap<String, Vec<K8sResource>>,
    pub deployment_plan: &'a [PlannedStep],
}

pub trait LabCheckRule {
    fn name(&self) -> &'static str;
    fn check(&self, ctx: &LabCheckContext<'_>) -> Vec<Diagnostic>;
}

pub fn lab_rules() -> Vec<Box<dyn LabCheckRule>> {
    vec![Box::new(plan::Plan)]
}

#[cfg(test)]
pub(crate) mod test_util {
    use std::path::{Path, PathBuf};

    use serde_yaml::Value;

    use crate::domain::plan::PlannedStep;
    use crate::lint::manifest::{K8sResource, parse_resource};

    pub(crate) fn planned_step(name: &str, kind: &str, params: serde_json::Value) -> PlannedStep {
        serde_json::from_value(serde_json::json!({
            "name": name,
            "origin": format!("lab.steps.{name}"),
            "kind": kind,
            "policy": { "retry": "idempotent" },
            "params": params,
        }))
        .expect("test plan step parses")
    }

    pub(crate) fn make_resource(yaml: &str) -> K8sResource {
        let value: Value = serde_yaml::from_str(yaml).unwrap();
        let source = Path::new("test.yaml");
        if let Some(resource) = parse_resource(&value, source) {
            return resource;
        }
        let mapping = value.as_mapping().expect("YAML root must be a mapping");
        let get = |key: &str| {
            mapping
                .get(Value::String(key.into()))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string()
        };
        let namespace = mapping
            .get(Value::String("metadata".into()))
            .and_then(|v| v.as_mapping())
            .and_then(|m| m.get(Value::String("namespace".into())))
            .and_then(|v| v.as_str())
            .map(String::from);
        let name = mapping
            .get(Value::String("metadata".into()))
            .and_then(|v| v.as_mapping())
            .and_then(|m| m.get(Value::String("name".into())))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        K8sResource {
            api_version: get("apiVersion"),
            kind: get("kind"),
            name,
            namespace,
            selector: None,
            pod_labels: None,
            configmap_refs: Vec::new(),
            secret_refs: Vec::new(),
            source_file: PathBuf::from("test.yaml"),
            raw: value,
            lint_skip: Vec::new(),
        }
    }
}

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use walkdir::WalkDir;

#[derive(Debug, Clone)]
pub struct K8sResource {
    pub api_version: String,
    pub kind: String,
    pub name: String,
    pub namespace: Option<String>,
    pub selector: Option<BTreeMap<String, String>>,
    pub pod_labels: Option<BTreeMap<String, String>>,
    pub configmap_refs: Vec<String>,
    pub secret_refs: Vec<String>,
    pub source_file: PathBuf,
    pub raw: serde_yaml::Value,
    pub lint_skip: Vec<String>,
}

impl K8sResource {
    pub fn display_id(&self) -> String {
        match &self.namespace {
            Some(ns) => format!("{}/{}/{}", ns, self.kind, self.name),
            None => format!("{}/{}", self.kind, self.name),
        }
    }

    pub fn is_crd(&self) -> bool {
        self.kind == "CustomResourceDefinition"
    }

    pub fn is_service(&self) -> bool {
        self.kind == "Service"
    }

    pub fn is_workload(&self) -> bool {
        matches!(
            self.kind.as_str(),
            "Deployment" | "DaemonSet" | "StatefulSet"
        )
    }

    pub fn is_configmap(&self) -> bool {
        self.kind == "ConfigMap"
    }

    pub fn is_secret(&self) -> bool {
        self.kind == "Secret"
    }

    pub fn has_lint_skip(&self, check: &str) -> bool {
        self.lint_skip.iter().any(|s| s == check)
    }
}

pub fn load_manifests(dir: &Path) -> Result<Vec<K8sResource>> {
    let mut resources = Vec::new();

    for entry in WalkDir::new(dir).follow_links(true) {
        let entry = entry.with_context(|| format!("walking {}", dir.display()))?;

        if !entry.file_type().is_file() {
            continue;
        }

        let path = entry.path();
        let file_name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");

        if !file_name.ends_with(".yaml") {
            continue;
        }
        if file_name.starts_with('.') || file_name == "fleet.yaml" {
            continue;
        }

        let content =
            std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;

        parse_yaml_documents(&content, path, &mut resources)?;
    }

    Ok(resources)
}

fn parse_yaml_documents(
    content: &str,
    source_file: &Path,
    out: &mut Vec<K8sResource>,
) -> Result<()> {
    for doc in serde_yaml::Deserializer::from_str(content) {
        let value: serde_yaml::Value = match serde_yaml::Value::deserialize(doc) {
            Ok(v) => v,
            Err(_) => continue,
        };

        if value.is_null() {
            continue;
        }

        if let Some(resource) = parse_resource(&value, source_file) {
            out.push(resource);
        }
    }
    Ok(())
}

pub(crate) fn parse_resource(value: &serde_yaml::Value, source_file: &Path) -> Option<K8sResource> {
    let mapping = value.as_mapping()?;

    let api_version = get_str(mapping, "apiVersion")?;
    let kind = get_str(mapping, "kind")?;

    let metadata = mapping.get(serde_yaml::Value::String("metadata".into()))?;
    let name = get_str(metadata.as_mapping()?, "name")?;
    let namespace = metadata.as_mapping().and_then(|m| get_str(m, "namespace"));

    let selector = extract_service_selector(mapping, &kind);
    let pod_labels = extract_pod_labels(mapping, &kind);
    let (configmap_refs, secret_refs) = extract_refs(mapping);
    let lint_skip = extract_lint_skip(metadata.as_mapping()?);

    Some(K8sResource {
        api_version,
        kind,
        name,
        namespace,
        selector,
        pod_labels,
        configmap_refs,
        secret_refs,
        source_file: source_file.to_path_buf(),
        raw: value.clone(),
        lint_skip,
    })
}

fn extract_lint_skip(metadata: &serde_yaml::Mapping) -> Vec<String> {
    metadata
        .get(serde_yaml::Value::String("annotations".into()))
        .and_then(|v| v.as_mapping())
        .and_then(|m| m.get(serde_yaml::Value::String("catallaxy.io/lint-skip".into())))
        .and_then(|v| v.as_str())
        .map(|s| s.split(',').map(|p| p.trim().to_string()).collect())
        .unwrap_or_default()
}

fn get_str(mapping: &serde_yaml::Mapping, key: &str) -> Option<String> {
    mapping
        .get(serde_yaml::Value::String(key.into()))?
        .as_str()
        .map(String::from)
}

fn extract_service_selector(
    mapping: &serde_yaml::Mapping,
    kind: &str,
) -> Option<BTreeMap<String, String>> {
    if kind != "Service" {
        return None;
    }
    let spec = mapping
        .get(serde_yaml::Value::String("spec".into()))?
        .as_mapping()?;
    let selector = spec
        .get(serde_yaml::Value::String("selector".into()))?
        .as_mapping()?;

    let mut map = BTreeMap::new();
    for (k, v) in selector {
        if let (Some(k), Some(v)) = (k.as_str(), v.as_str()) {
            map.insert(k.to_string(), v.to_string());
        }
    }
    if map.is_empty() { None } else { Some(map) }
}

fn extract_pod_labels(
    mapping: &serde_yaml::Mapping,
    kind: &str,
) -> Option<BTreeMap<String, String>> {
    if !matches!(kind, "Deployment" | "DaemonSet" | "StatefulSet") {
        return None;
    }
    let spec = mapping
        .get(serde_yaml::Value::String("spec".into()))?
        .as_mapping()?;
    let template = spec
        .get(serde_yaml::Value::String("template".into()))?
        .as_mapping()?;
    let metadata = template
        .get(serde_yaml::Value::String("metadata".into()))?
        .as_mapping()?;
    let labels = metadata
        .get(serde_yaml::Value::String("labels".into()))?
        .as_mapping()?;

    let mut map = BTreeMap::new();
    for (k, v) in labels {
        if let (Some(k), Some(v)) = (k.as_str(), v.as_str()) {
            map.insert(k.to_string(), v.to_string());
        }
    }
    if map.is_empty() { None } else { Some(map) }
}

fn optional_aware_ref(m: &serde_yaml::Mapping, key: &str) -> Option<String> {
    let r = m
        .get(serde_yaml::Value::String(key.into()))
        .and_then(|r| r.as_mapping())?;
    let optional = r
        .get(serde_yaml::Value::String("optional".into()))
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    if optional {
        return None;
    }
    get_str(r, "name")
}

fn extract_refs(mapping: &serde_yaml::Mapping) -> (Vec<String>, Vec<String>) {
    let mut cm_refs = Vec::new();
    let mut secret_refs = Vec::new();

    let spec = match mapping.get(serde_yaml::Value::String("spec".into())) {
        Some(v) => v,
        None => return (cm_refs, secret_refs),
    };

    let pod_spec = spec
        .as_mapping()
        .and_then(|s| s.get(serde_yaml::Value::String("template".into())))
        .and_then(|t| t.as_mapping())
        .and_then(|t| t.get(serde_yaml::Value::String("spec".into())))
        .or(Some(spec));

    if let Some(pod_spec) = pod_spec.and_then(|s| s.as_mapping()) {
        if let Some(volumes) = pod_spec
            .get(serde_yaml::Value::String("volumes".into()))
            .and_then(|v| v.as_sequence())
        {
            for vol in volumes {
                if let Some(m) = vol.as_mapping() {
                    if let Some(cm) = m
                        .get(serde_yaml::Value::String("configMap".into()))
                        .and_then(|cm| cm.as_mapping())
                    {
                        let optional = cm
                            .get(serde_yaml::Value::String("optional".into()))
                            .and_then(|v| v.as_bool())
                            .unwrap_or(false);
                        if !optional && let Some(name) = get_str(cm, "name") {
                            cm_refs.push(name);
                        }
                    }
                    if let Some(secret) = m
                        .get(serde_yaml::Value::String("secret".into()))
                        .and_then(|s| s.as_mapping())
                    {
                        let optional = secret
                            .get(serde_yaml::Value::String("optional".into()))
                            .and_then(|v| v.as_bool())
                            .unwrap_or(false);
                        if !optional && let Some(name) = get_str(secret, "secretName") {
                            secret_refs.push(name);
                        }
                    }
                }
            }
        }

        for container_key in &["containers", "initContainers"] {
            if let Some(containers) = pod_spec
                .get(serde_yaml::Value::String((*container_key).into()))
                .and_then(|c| c.as_sequence())
            {
                for container in containers {
                    let container = match container.as_mapping() {
                        Some(m) => m,
                        None => continue,
                    };

                    if let Some(env_from) = container
                        .get(serde_yaml::Value::String("envFrom".into()))
                        .and_then(|e| e.as_sequence())
                    {
                        for ef in env_from {
                            if let Some(m) = ef.as_mapping() {
                                if let Some(name) = optional_aware_ref(m, "configMapRef") {
                                    cm_refs.push(name);
                                }
                                if let Some(name) = optional_aware_ref(m, "secretRef") {
                                    secret_refs.push(name);
                                }
                            }
                        }
                    }

                    if let Some(env) = container
                        .get(serde_yaml::Value::String("env".into()))
                        .and_then(|e| e.as_sequence())
                    {
                        for e in env {
                            if let Some(vf) = e
                                .as_mapping()
                                .and_then(|m| m.get(serde_yaml::Value::String("valueFrom".into())))
                                .and_then(|v| v.as_mapping())
                            {
                                if let Some(name) = optional_aware_ref(vf, "configMapKeyRef") {
                                    cm_refs.push(name);
                                }
                                if let Some(name) = optional_aware_ref(vf, "secretKeyRef") {
                                    secret_refs.push(name);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    (cm_refs, secret_refs)
}

use serde::Deserialize;

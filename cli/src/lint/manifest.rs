//! YAML manifest loading and Kubernetes resource model

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use walkdir::WalkDir;

/// Minimal Kubernetes resource identity parsed from YAML manifests
#[derive(Debug, Clone)]
pub struct K8sResource {
    pub api_version: String,
    pub kind: String,
    pub name: String,
    pub namespace: Option<String>,
    /// Service.spec.selector (for selector check)
    pub selector: Option<BTreeMap<String, String>>,
    /// Workload .spec.template.metadata.labels (for selector check)
    pub pod_labels: Option<BTreeMap<String, String>>,
    /// ConfigMap names referenced by this resource
    pub configmap_refs: Vec<String>,
    /// Secret names referenced by this resource
    pub secret_refs: Vec<String>,
    /// Source file for error reporting
    pub source_file: PathBuf,
}

impl K8sResource {
    /// Display identity for diagnostics (e.g. "Deployment/my-app")
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
}

/// Load all Kubernetes resources from YAML files in a directory tree.
///
/// Follows symlinks (out.package uses them), skips dotfiles and fleet metadata.
pub fn load_manifests(dir: &Path) -> Result<Vec<K8sResource>> {
    let mut resources = Vec::new();

    for entry in WalkDir::new(dir).follow_links(true) {
        let entry = entry.with_context(|| format!("walking {}", dir.display()))?;

        if !entry.file_type().is_file() {
            continue;
        }

        let path = entry.path();
        let file_name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");

        // Skip non-YAML and metadata files
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

/// Parse a potentially multi-document YAML string into K8sResources.
fn parse_yaml_documents(
    content: &str,
    source_file: &Path,
    out: &mut Vec<K8sResource>,
) -> Result<()> {
    for doc in serde_yaml::Deserializer::from_str(content) {
        let value: serde_yaml::Value = match serde_yaml::Value::deserialize(doc) {
            Ok(v) => v,
            Err(_) => continue, // skip unparseable documents (empty, comments-only)
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

/// Extract a K8sResource from a parsed YAML value.
/// Returns None if the value doesn't look like a K8s resource.
fn parse_resource(value: &serde_yaml::Value, source_file: &Path) -> Option<K8sResource> {
    let mapping = value.as_mapping()?;

    let api_version = get_str(mapping, "apiVersion")?;
    let kind = get_str(mapping, "kind")?;

    let metadata = mapping.get(serde_yaml::Value::String("metadata".into()))?;
    let name = get_str(metadata.as_mapping()?, "name")?;
    let namespace = metadata.as_mapping().and_then(|m| get_str(m, "namespace"));

    let selector = extract_service_selector(mapping, &kind);
    let pod_labels = extract_pod_labels(mapping, &kind);
    let (configmap_refs, secret_refs) = extract_refs(mapping);

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
    })
}

fn get_str(mapping: &serde_yaml::Mapping, key: &str) -> Option<String> {
    mapping
        .get(serde_yaml::Value::String(key.into()))?
        .as_str()
        .map(String::from)
}

/// Extract Service.spec.selector as a string map
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

/// Extract workload .spec.template.metadata.labels
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

/// Extract ConfigMap and Secret references from a resource's spec.
///
/// Covers common patterns:
/// - volumes[].configMap.name / volumes[].secret.secretName
/// - containers[].envFrom[].configMapRef.name / secretRef.name
/// - containers[].env[].valueFrom.configMapKeyRef.name / secretKeyRef.name
fn extract_refs(mapping: &serde_yaml::Mapping) -> (Vec<String>, Vec<String>) {
    let mut cm_refs = Vec::new();
    let mut secret_refs = Vec::new();

    let spec = match mapping.get(serde_yaml::Value::String("spec".into())) {
        Some(v) => v,
        None => return (cm_refs, secret_refs),
    };

    // For workloads, look inside spec.template.spec; for Pods, look in spec directly
    let pod_spec = spec
        .as_mapping()
        .and_then(|s| s.get(serde_yaml::Value::String("template".into())))
        .and_then(|t| t.as_mapping())
        .and_then(|t| t.get(serde_yaml::Value::String("spec".into())))
        .or(Some(spec));

    if let Some(pod_spec) = pod_spec.and_then(|s| s.as_mapping()) {
        // volumes[].configMap.name / volumes[].secret.secretName
        if let Some(volumes) = pod_spec
            .get(serde_yaml::Value::String("volumes".into()))
            .and_then(|v| v.as_sequence())
        {
            for vol in volumes {
                if let Some(m) = vol.as_mapping() {
                    if let Some(name) = m
                        .get(serde_yaml::Value::String("configMap".into()))
                        .and_then(|cm| cm.as_mapping())
                        .and_then(|cm| get_str(cm, "name"))
                    {
                        cm_refs.push(name);
                    }
                    if let Some(name) = m
                        .get(serde_yaml::Value::String("secret".into()))
                        .and_then(|s| s.as_mapping())
                        .and_then(|s| get_str(s, "secretName"))
                    {
                        secret_refs.push(name);
                    }
                }
            }
        }

        // containers[].envFrom / env[].valueFrom
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

                    // envFrom[].configMapRef.name / secretRef.name
                    if let Some(env_from) = container
                        .get(serde_yaml::Value::String("envFrom".into()))
                        .and_then(|e| e.as_sequence())
                    {
                        for ef in env_from {
                            if let Some(m) = ef.as_mapping() {
                                if let Some(name) = m
                                    .get(serde_yaml::Value::String("configMapRef".into()))
                                    .and_then(|r| r.as_mapping())
                                    .and_then(|r| get_str(r, "name"))
                                {
                                    cm_refs.push(name);
                                }
                                if let Some(name) = m
                                    .get(serde_yaml::Value::String("secretRef".into()))
                                    .and_then(|r| r.as_mapping())
                                    .and_then(|r| get_str(r, "name"))
                                {
                                    secret_refs.push(name);
                                }
                            }
                        }
                    }

                    // env[].valueFrom.configMapKeyRef.name / secretKeyRef.name
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
                                if let Some(name) = vf
                                    .get(serde_yaml::Value::String("configMapKeyRef".into()))
                                    .and_then(|r| r.as_mapping())
                                    .and_then(|r| get_str(r, "name"))
                                {
                                    cm_refs.push(name);
                                }
                                if let Some(name) = vf
                                    .get(serde_yaml::Value::String("secretKeyRef".into()))
                                    .and_then(|r| r.as_mapping())
                                    .and_then(|r| get_str(r, "name"))
                                {
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

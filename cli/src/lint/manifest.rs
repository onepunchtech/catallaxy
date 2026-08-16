use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::Deserialize;
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

        let content = crate::io::fs::read_to_string(path)
            .with_context(|| format!("reading {}", path.display()))?;

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

fn field<'a>(m: &'a serde_yaml::Mapping, key: &str) -> Option<&'a serde_yaml::Value> {
    m.get(serde_yaml::Value::String(key.into()))
}

fn submap<'a>(m: &'a serde_yaml::Mapping, key: &str) -> Option<&'a serde_yaml::Mapping> {
    field(m, key)?.as_mapping()
}

fn subseq<'a>(m: &'a serde_yaml::Mapping, key: &str) -> Option<&'a serde_yaml::Sequence> {
    field(m, key)?.as_sequence()
}

fn is_optional(m: &serde_yaml::Mapping) -> bool {
    field(m, "optional")
        .and_then(|v| v.as_bool())
        .unwrap_or(false)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RefKind {
    ConfigMap,
    Secret,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Ref {
    kind: RefKind,
    name: String,
}

fn required_ref(m: &serde_yaml::Mapping, key: &str, name_key: &str, kind: RefKind) -> Option<Ref> {
    let r = submap(m, key)?;
    if is_optional(r) {
        return None;
    }
    get_str(r, name_key).map(|name| Ref { kind, name })
}

fn pod_spec_of(mapping: &serde_yaml::Mapping) -> Option<&serde_yaml::Mapping> {
    let spec = field(mapping, "spec")?;
    let nested = spec
        .as_mapping()
        .and_then(|s| submap(s, "template"))
        .and_then(|t| field(t, "spec"));

    nested.or(Some(spec))?.as_mapping()
}

fn volume_refs(pod: &serde_yaml::Mapping) -> Vec<Ref> {
    let Some(volumes) = subseq(pod, "volumes") else {
        return Vec::new();
    };

    volumes
        .iter()
        .filter_map(|v| v.as_mapping())
        .flat_map(|vol| {
            [
                required_ref(vol, "configMap", "name", RefKind::ConfigMap),
                required_ref(vol, "secret", "secretName", RefKind::Secret),
            ]
        })
        .flatten()
        .collect()
}

fn env_from_refs(container: &serde_yaml::Mapping) -> Vec<Ref> {
    refs_under(container, "envFrom", "configMapRef", "secretRef", |m| {
        Some(m)
    })
}

fn env_refs(container: &serde_yaml::Mapping) -> Vec<Ref> {
    refs_under(container, "env", "configMapKeyRef", "secretKeyRef", |m| {
        submap(m, "valueFrom")
    })
}

fn refs_under<'a>(
    container: &'a serde_yaml::Mapping,
    list_key: &str,
    cm_key: &str,
    secret_key: &str,
    source: impl Fn(&'a serde_yaml::Mapping) -> Option<&'a serde_yaml::Mapping>,
) -> Vec<Ref> {
    let Some(entries) = subseq(container, list_key) else {
        return Vec::new();
    };

    entries
        .iter()
        .filter_map(|e| e.as_mapping())
        .filter_map(source)
        .flat_map(|m| {
            [
                required_ref(m, cm_key, "name", RefKind::ConfigMap),
                required_ref(m, secret_key, "name", RefKind::Secret),
            ]
        })
        .flatten()
        .collect()
}

fn container_refs(pod: &serde_yaml::Mapping) -> Vec<Ref> {
    ["containers", "initContainers"]
        .into_iter()
        .filter_map(|key| subseq(pod, key))
        .flatten()
        .filter_map(|c| c.as_mapping())
        .flat_map(|c| {
            let mut refs = env_from_refs(c);
            refs.extend(env_refs(c));
            refs
        })
        .collect()
}

fn extract_refs(mapping: &serde_yaml::Mapping) -> (Vec<String>, Vec<String>) {
    let Some(pod) = pod_spec_of(mapping) else {
        return (Vec::new(), Vec::new());
    };

    let mut refs = volume_refs(pod);
    refs.extend(container_refs(pod));

    let (configmaps, secrets): (Vec<Ref>, Vec<Ref>) =
        refs.into_iter().partition(|r| r.kind == RefKind::ConfigMap);

    (
        configmaps.into_iter().map(|r| r.name).collect(),
        secrets.into_iter().map(|r| r.name).collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn refs_of(yaml: &str) -> (Vec<String>, Vec<String>) {
        let value: serde_yaml::Value = serde_yaml::from_str(yaml).expect("fixture parses");
        extract_refs(value.as_mapping().expect("fixture is a mapping"))
    }

    fn in_pod(pod_spec: &str) -> String {
        let indented: String = pod_spec.lines().map(|l| format!("      {l}\n")).collect();
        format!("spec:\n  template:\n    spec:\n{indented}")
    }

    #[test]
    fn a_resource_with_no_spec_references_nothing() {
        assert_eq!(refs_of("kind: ConfigMap\n"), (vec![], vec![]));
    }

    #[test]
    fn volumes_contribute_configmaps_and_secrets() {
        let (cms, secrets) = refs_of(&in_pod(
            r#"volumes:
  - configMap:
      name: cm-one
  - secret:
      secretName: sec-one"#,
        ));

        assert_eq!(cms, vec!["cm-one"]);
        assert_eq!(secrets, vec!["sec-one"]);
    }

    #[test]
    fn a_secret_volume_is_named_by_secret_name_not_name() {
        let (_, secrets) = refs_of(&in_pod(
            r#"volumes:
  - secret:
      name: ignored
      secretName: the-real-one"#,
        ));

        assert_eq!(secrets, vec!["the-real-one"]);
    }

    #[test]
    fn an_optional_reference_is_not_a_reference() {
        let (cms, secrets) = refs_of(&in_pod(
            r#"volumes:
  - configMap:
      name: maybe-cm
      optional: true
  - secret:
      secretName: maybe-sec
      optional: true"#,
        ));

        assert!(cms.is_empty(), "{cms:?}");
        assert!(secrets.is_empty(), "{secrets:?}");
    }

    #[test]
    fn env_from_and_env_value_from_both_count() {
        let (cms, secrets) = refs_of(&in_pod(
            r#"containers:
  - name: c
    envFrom:
      - configMapRef:
          name: from-cm
      - secretRef:
          name: from-sec
    env:
      - name: A
        valueFrom:
          configMapKeyRef:
            name: key-cm
      - name: B
        valueFrom:
          secretKeyRef:
            name: key-sec"#,
        ));

        assert_eq!(cms, vec!["from-cm", "key-cm"]);
        assert_eq!(secrets, vec!["from-sec", "key-sec"]);
    }

    #[test]
    fn init_containers_are_searched_after_containers() {
        let (cms, _) = refs_of(&in_pod(
            r#"containers:
  - name: main
    envFrom:
      - configMapRef:
          name: main-cm
initContainers:
  - name: init
    envFrom:
      - configMapRef:
          name: init-cm"#,
        ));

        assert_eq!(cms, vec!["main-cm", "init-cm"]);
    }

    #[test]
    fn a_bare_pod_spec_is_read_without_a_template() {
        let (cms, _) = refs_of(
            r#"spec:
  containers:
    - name: c
      envFrom:
        - configMapRef:
            name: bare"#,
        );

        assert_eq!(cms, vec!["bare"]);
    }

    #[test]
    fn volumes_come_before_container_references() {
        let (cms, _) = refs_of(&in_pod(
            r#"volumes:
  - configMap:
      name: from-volume
containers:
  - name: c
    envFrom:
      - configMapRef:
          name: from-container"#,
        ));

        assert_eq!(cms, vec!["from-volume", "from-container"]);
    }

    #[test]
    fn an_entry_that_is_not_a_mapping_is_skipped_rather_than_fatal() {
        let (cms, _) = refs_of(&in_pod(
            r#"containers:
  - "not-a-mapping"
  - name: c
    envFrom:
      - configMapRef:
          name: survives"#,
        ));

        assert_eq!(cms, vec!["survives"]);
    }
}

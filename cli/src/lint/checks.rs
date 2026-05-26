//! Lint check implementations
//!
//! Each check is a pure function that takes resources and metadata,
//! returning a list of diagnostics.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;

use serde_yaml::Value;

use super::manifest::K8sResource;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Severity {
    Error,
    Warning,
}

#[derive(Debug, Clone)]
pub struct Diagnostic {
    pub severity: Severity,
    pub check: &'static str,
    pub cluster: String,
    pub file: PathBuf,
    pub resource: String,
    pub message: String,
}

/// Verify every resource has apiVersion, kind, and metadata.name.
///
/// Resources that failed to parse are already excluded by the loader,
/// so this catches resources with empty fields.
pub fn check_schema(resources: &[K8sResource], cluster: &str) -> Vec<Diagnostic> {
    let mut diags = Vec::new();

    for r in resources {
        if r.api_version.is_empty() {
            diags.push(Diagnostic {
                severity: Severity::Error,
                check: "schema",
                cluster: cluster.to_string(),
                file: r.source_file.clone(),
                resource: r.display_id(),
                message: "missing apiVersion".to_string(),
            });
        }
        if r.kind.is_empty() {
            diags.push(Diagnostic {
                severity: Severity::Error,
                check: "schema",
                cluster: cluster.to_string(),
                file: r.source_file.clone(),
                resource: r.display_id(),
                message: "missing kind".to_string(),
            });
        }
        if r.name.is_empty() {
            diags.push(Diagnostic {
                severity: Severity::Error,
                check: "schema",
                cluster: cluster.to_string(),
                file: r.source_file.clone(),
                resource: r.display_id(),
                message: "missing metadata.name".to_string(),
            });
        }
    }

    diags
}

/// Verify no two resources share the same (apiVersion, kind, namespace, name) identity.
pub fn check_identity(resources: &[K8sResource], cluster: &str) -> Vec<Diagnostic> {
    let mut seen: HashMap<(String, String, Option<String>, String), &K8sResource> = HashMap::new();
    let mut diags = Vec::new();

    for r in resources {
        let key = (
            r.api_version.clone(),
            r.kind.clone(),
            r.namespace.clone(),
            r.name.clone(),
        );

        if let Some(first) = seen.get(&key) {
            diags.push(Diagnostic {
                severity: Severity::Error,
                check: "identity",
                cluster: cluster.to_string(),
                file: r.source_file.clone(),
                resource: r.display_id(),
                message: format!(
                    "duplicate resource identity {}/{} (first seen in {})",
                    r.api_version,
                    r.kind,
                    first.source_file.display()
                ),
            });
        } else {
            seen.insert(key, r);
        }
    }

    diags
}

/// Verify prefix completeness: all non-CRD resources must have names
/// starting with the prefix, and lab-owned namespaces must be prefixed.
///
/// This guarantees that two lab instances with distinct prefixes produce
/// non-overlapping Kubernetes resource identities.
pub fn check_prefix(
    resources: &[K8sResource],
    cluster: &str,
    prefix: &str,
    lab_namespaces: &[String],
) -> Vec<Diagnostic> {
    if prefix.is_empty() {
        return Vec::new();
    }

    let expected_prefix = format!("{prefix}-");
    let lab_ns_set: HashSet<&str> = lab_namespaces.iter().map(|s| s.as_str()).collect();
    let mut diags = Vec::new();

    for r in resources {
        // CRDs are intentionally not prefixed (names are API group identifiers)
        if r.is_crd() {
            continue;
        }

        // Check metadata.name starts with prefix
        if !r.name.starts_with(&expected_prefix) {
            diags.push(Diagnostic {
                severity: Severity::Error,
                check: "prefix",
                cluster: cluster.to_string(),
                file: r.source_file.clone(),
                resource: r.display_id(),
                message: format!(
                    "resource name '{}' missing prefix '{}'",
                    r.name, expected_prefix
                ),
            });
        }

        // Check namespace: if it matches an unprefixed lab namespace, it wasn't prefixed
        if let Some(ns) = &r.namespace {
            if lab_ns_set.contains(ns.as_str()) {
                diags.push(Diagnostic {
                    severity: Severity::Error,
                    check: "prefix",
                    cluster: cluster.to_string(),
                    file: r.source_file.clone(),
                    resource: r.display_id(),
                    message: format!(
                        "namespace '{}' not prefixed (expected '{}{}')",
                        ns, expected_prefix, ns
                    ),
                });
            }
        }
    }

    diags
}

/// Well-known kube-system service names whose workloads are managed by the
/// kubelet rather than deployed via manifests.
const KUBE_SYSTEM_SERVICES: &[&str] = &[
    "kube-controller-manager",
    "kube-scheduler",
    "kube-proxy",
    "kube-etcd",
    "coredns",
];

/// Returns true if this Service targets a well-known kube-system component
/// whose workload is managed by the kubelet, not our manifests.
fn is_kube_system_service(r: &K8sResource) -> bool {
    if r.namespace.as_deref() != Some("kube-system") {
        return false;
    }
    KUBE_SYSTEM_SERVICES
        .iter()
        .any(|svc| r.name.ends_with(svc))
}

/// Returns true if this Service targets operator-managed workloads (Prometheus,
/// Alertmanager) that are created by the operator at runtime, not via manifests.
fn is_operator_managed_workload_service(r: &K8sResource) -> bool {
    if let Some(selector) = &r.selector {
        // Prometheus Operator creates Prometheus/Alertmanager StatefulSets at
        // runtime from Prometheus/Alertmanager CRs — the Services target these
        // via app.kubernetes.io/name labels.
        if let Some(app_name) = selector.get("app.kubernetes.io/name") {
            return matches!(app_name.as_str(), "prometheus" | "alertmanager");
        }
    }
    false
}

/// Verify Service selectors match at least one workload's pod template labels
/// in the same namespace.
pub fn check_selectors(resources: &[K8sResource], cluster: &str) -> Vec<Diagnostic> {
    // Index workloads by namespace
    let mut workloads_by_ns: HashMap<Option<&str>, Vec<&BTreeMap<String, String>>> = HashMap::new();
    for r in resources {
        if r.is_workload() {
            if let Some(labels) = &r.pod_labels {
                workloads_by_ns
                    .entry(r.namespace.as_deref())
                    .or_default()
                    .push(labels);
            }
        }
    }

    let mut diags = Vec::new();

    for r in resources {
        if !r.is_service() {
            continue;
        }
        if r.has_lint_skip("selector") {
            continue;
        }
        // Skip well-known kube-system services and operator-managed workloads
        if is_kube_system_service(r) || is_operator_managed_workload_service(r) {
            continue;
        }

        let selector = match &r.selector {
            Some(s) => s,
            None => continue,
        };

        let workloads = workloads_by_ns
            .get(&r.namespace.as_deref())
            .map(|v| v.as_slice())
            .unwrap_or(&[]);

        let has_match = workloads.iter().any(|labels| {
            selector
                .iter()
                .all(|(k, v)| labels.get(k).map_or(false, |lv| lv == v))
        });

        if !has_match {
            diags.push(Diagnostic {
                severity: Severity::Warning,
                check: "selector",
                cluster: cluster.to_string(),
                file: r.source_file.clone(),
                resource: r.display_id(),
                message: "no matching workload found for service selector".to_string(),
            });
        }
    }

    diags
}

/// Validate custom resources against CRD OpenAPI v3 schemas.
///
/// Extracts schemas from CRD resources, then checks each custom resource
/// for missing required fields, type mismatches, and invalid enum values.
pub fn check_crd_schema(resources: &[K8sResource], cluster: &str) -> Vec<Diagnostic> {
    let schemas = extract_crd_schemas(resources);
    if schemas.is_empty() {
        return Vec::new();
    }

    let mut diags = Vec::new();

    for r in resources {
        if r.is_crd() {
            continue;
        }

        // Look up CRD schema by group/version/kind
        let key = crd_key(&r.api_version, &r.kind);
        let schema = match schemas.get(&key) {
            Some(s) => s,
            None => continue, // not a custom resource or CRD not in manifests
        };

        // Validate the resource's top-level properties against the schema
        validate_object(&r.raw, schema, "", r, cluster, &mut diags);
    }

    diags
}

/// Key for CRD schema lookup: "group/version/Kind"
fn crd_key(api_version: &str, kind: &str) -> String {
    format!("{}/{}", api_version, kind)
}

/// A simplified OpenAPI v3 schema node extracted from a CRD.
#[derive(Debug)]
struct SchemaNode {
    schema_type: Option<String>,
    required: Vec<String>,
    properties: HashMap<String, SchemaNode>,
    items: Option<Box<SchemaNode>>,
    enum_values: Vec<String>,
    additional_properties: Option<Box<SchemaNode>>,
}

/// Extract CRD schemas into a lookup map keyed by "apiVersion/Kind".
fn extract_crd_schemas(resources: &[K8sResource]) -> HashMap<String, SchemaNode> {
    let mut schemas = HashMap::new();

    for r in resources {
        if !r.is_crd() {
            continue;
        }

        let mapping = match r.raw.as_mapping() {
            Some(m) => m,
            None => continue,
        };

        let spec = match mapping
            .get(&Value::String("spec".into()))
            .and_then(|v| v.as_mapping())
        {
            Some(s) => s,
            None => continue,
        };

        let group = match spec
            .get(&Value::String("group".into()))
            .and_then(|v| v.as_str())
        {
            Some(g) => g,
            None => continue,
        };

        let names = match spec
            .get(&Value::String("names".into()))
            .and_then(|v| v.as_mapping())
        {
            Some(n) => n,
            None => continue,
        };

        let kind = match names
            .get(&Value::String("kind".into()))
            .and_then(|v| v.as_str())
        {
            Some(k) => k,
            None => continue,
        };

        let versions = match spec
            .get(&Value::String("versions".into()))
            .and_then(|v| v.as_sequence())
        {
            Some(v) => v,
            None => continue,
        };

        for version_entry in versions {
            let version_map = match version_entry.as_mapping() {
                Some(m) => m,
                None => continue,
            };

            let version_name = match version_map
                .get(&Value::String("name".into()))
                .and_then(|v| v.as_str())
            {
                Some(n) => n,
                None => continue,
            };

            let openapi_schema = match version_map
                .get(&Value::String("schema".into()))
                .and_then(|v| v.as_mapping())
                .and_then(|m| m.get(&Value::String("openAPIV3Schema".into())))
            {
                Some(s) => s,
                None => continue,
            };

            let node = parse_schema_node(openapi_schema);
            let key = format!("{}/{}/{}", group, version_name, kind);
            schemas.insert(key, node);
        }
    }

    schemas
}

/// Recursively parse an OpenAPI v3 schema value into a SchemaNode.
fn parse_schema_node(value: &Value) -> SchemaNode {
    let mapping = match value.as_mapping() {
        Some(m) => m,
        None => {
            return SchemaNode {
                schema_type: None,
                required: Vec::new(),
                properties: HashMap::new(),
                items: None,
                enum_values: Vec::new(),
                additional_properties: None,
            }
        }
    };

    let schema_type = mapping
        .get(&Value::String("type".into()))
        .and_then(|v| v.as_str())
        .map(String::from);

    let required = mapping
        .get(&Value::String("required".into()))
        .and_then(|v| v.as_sequence())
        .map(|seq| {
            seq.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();

    let properties = mapping
        .get(&Value::String("properties".into()))
        .and_then(|v| v.as_mapping())
        .map(|props| {
            props
                .iter()
                .filter_map(|(k, v)| {
                    k.as_str().map(|k| (k.to_string(), parse_schema_node(v)))
                })
                .collect()
        })
        .unwrap_or_default();

    let items = mapping
        .get(&Value::String("items".into()))
        .map(|v| Box::new(parse_schema_node(v)));

    let enum_values = mapping
        .get(&Value::String("enum".into()))
        .and_then(|v| v.as_sequence())
        .map(|seq| {
            seq.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();

    let additional_properties = mapping
        .get(&Value::String("additionalProperties".into()))
        .and_then(|v| {
            // additionalProperties can be a bool or a schema object
            if v.is_bool() {
                None
            } else {
                Some(Box::new(parse_schema_node(v)))
            }
        });

    SchemaNode {
        schema_type,
        required,
        properties,
        items,
        enum_values,
        additional_properties,
    }
}

/// Validate a YAML value against a schema node, collecting diagnostics.
fn validate_object(
    value: &Value,
    schema: &SchemaNode,
    path: &str,
    resource: &K8sResource,
    cluster: &str,
    diags: &mut Vec<Diagnostic>,
) {
    // Check type matches
    if let Some(ref expected_type) = schema.schema_type {
        let actual_type = yaml_type_name(value);
        let type_ok = match expected_type.as_str() {
            "object" => value.is_mapping() || value.is_null(),
            "array" => value.is_sequence() || value.is_null(),
            "string" => value.is_string() || value.is_null(),
            "integer" => value.is_i64() || value.is_u64() || value.is_null(),
            "number" => value.is_number() || value.is_null(),
            "boolean" => value.is_bool() || value.is_null(),
            _ => true,
        };
        if !type_ok {
            diags.push(Diagnostic {
                severity: Severity::Warning,
                check: "crd-schema",
                cluster: cluster.to_string(),
                file: resource.source_file.clone(),
                resource: resource.display_id(),
                message: format!(
                    "{}: expected type '{}', got '{}'",
                    field_path(path),
                    expected_type,
                    actual_type
                ),
            });
            return;
        }
    }

    // Check enum constraint
    if !schema.enum_values.is_empty() {
        if let Some(s) = value.as_str() {
            if !schema.enum_values.contains(&s.to_string()) {
                diags.push(Diagnostic {
                    severity: Severity::Error,
                    check: "crd-schema",
                    cluster: cluster.to_string(),
                    file: resource.source_file.clone(),
                    resource: resource.display_id(),
                    message: format!(
                        "{}: value '{}' not in allowed values [{}]",
                        field_path(path),
                        s,
                        schema.enum_values.join(", ")
                    ),
                });
            }
        }
    }

    // For objects: check required fields and recurse into properties
    if let Some(mapping) = value.as_mapping() {
        for req in &schema.required {
            if !mapping.contains_key(&Value::String(req.clone().into())) {
                diags.push(Diagnostic {
                    severity: Severity::Error,
                    check: "crd-schema",
                    cluster: cluster.to_string(),
                    file: resource.source_file.clone(),
                    resource: resource.display_id(),
                    message: format!(
                        "{}: missing required field '{}'",
                        field_path(path),
                        req
                    ),
                });
            }
        }

        for (k, v) in mapping {
            if let Some(key) = k.as_str() {
                let child_path = if path.is_empty() {
                    key.to_string()
                } else {
                    format!("{}.{}", path, key)
                };

                if let Some(prop_schema) = schema.properties.get(key) {
                    validate_object(v, prop_schema, &child_path, resource, cluster, diags);
                } else if let Some(ref ap) = schema.additional_properties {
                    validate_object(v, ap, &child_path, resource, cluster, diags);
                }
            }
        }
    }

    // For arrays: validate each item
    if let Some(seq) = value.as_sequence() {
        if let Some(ref items_schema) = schema.items {
            for (i, item) in seq.iter().enumerate() {
                let child_path = format!("{}[{}]", path, i);
                validate_object(item, items_schema, &child_path, resource, cluster, diags);
            }
        }
    }
}

fn yaml_type_name(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Sequence(_) => "array",
        Value::Mapping(_) => "object",
        Value::Tagged(_) => "tagged",
    }
}

fn field_path(path: &str) -> &str {
    if path.is_empty() {
        "(root)"
    } else {
        path
    }
}

/// Suffix patterns for Secrets that are commonly generated at runtime by
/// operators (webhook admission certs, TLS certs, password secrets).
const OPERATOR_GENERATED_SECRET_SUFFIXES: &[&str] = &[
    "-tls",
    "-cert",
    "-admission",
];

/// Secret names that are known to be generated by operators at runtime.
const OPERATOR_GENERATED_SECRET_NAMES: &[&str] = &[
    // ArgoCD operator generates these
    "argocd-redis",
];

/// Returns true if a Secret name matches a pattern for operator-generated secrets.
fn is_operator_generated_secret(name: &str, resources: &[K8sResource]) -> bool {
    if OPERATOR_GENERATED_SECRET_SUFFIXES
        .iter()
        .any(|suffix| name.ends_with(suffix))
    {
        return true;
    }
    if OPERATOR_GENERATED_SECRET_NAMES.contains(&name) {
        return true;
    }
    // CNPG operator creates `<cluster-name>-app` secrets for each Cluster CR
    if let Some(cluster_name) = name.strip_suffix("-app") {
        if resources.iter().any(|r| {
            r.kind == "Cluster"
                && r.api_version.starts_with("postgresql.cnpg.io/")
                && r.name == cluster_name
        }) {
            return true;
        }
    }
    false
}

/// ConfigMap/Secret names that are provided by other phases or by trust-manager
/// at runtime and are expected to exist before workloads start.
const CROSS_PHASE_RESOURCES: &[&str] = &[
    "lab-ca-bundle",
];

fn is_cross_phase_resource(name: &str) -> bool {
    CROSS_PHASE_RESOURCES.contains(&name)
}

/// Verify ConfigMap/Secret references point to existing resources in the same namespace.
pub fn check_references(resources: &[K8sResource], cluster: &str) -> Vec<Diagnostic> {
    // Index existing ConfigMaps and Secrets by (namespace, name)
    let mut configmaps: HashSet<(Option<&str>, &str)> = HashSet::new();
    let mut secrets: HashSet<(Option<&str>, &str)> = HashSet::new();

    for r in resources {
        if r.is_configmap() {
            configmaps.insert((r.namespace.as_deref(), &r.name));
        }
        if r.is_secret() {
            secrets.insert((r.namespace.as_deref(), &r.name));
        }
    }

    let mut diags = Vec::new();

    for r in resources {
        if r.has_lint_skip("reference") {
            continue;
        }

        for cm_ref in &r.configmap_refs {
            if configmaps.contains(&(r.namespace.as_deref(), cm_ref.as_str())) {
                continue;
            }
            if is_cross_phase_resource(cm_ref) {
                continue;
            }
            diags.push(Diagnostic {
                severity: Severity::Warning,
                check: "reference",
                cluster: cluster.to_string(),
                file: r.source_file.clone(),
                resource: r.display_id(),
                message: format!("references ConfigMap '{}' which does not exist", cm_ref),
            });
        }
        for secret_ref in &r.secret_refs {
            if secrets.contains(&(r.namespace.as_deref(), secret_ref.as_str())) {
                continue;
            }
            if is_operator_generated_secret(secret_ref, resources) {
                continue;
            }
            diags.push(Diagnostic {
                severity: Severity::Warning,
                check: "reference",
                cluster: cluster.to_string(),
                file: r.source_file.clone(),
                resource: r.display_id(),
                message: format!("references Secret '{}' which does not exist", secret_ref),
            });
        }
    }

    diags
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn make_resource(yaml: &str) -> K8sResource {
        let value: Value = serde_yaml::from_str(yaml).unwrap();
        let mapping = value.as_mapping().unwrap();
        K8sResource {
            api_version: mapping
                .get(&Value::String("apiVersion".into()))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
            kind: mapping
                .get(&Value::String("kind".into()))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
            name: mapping
                .get(&Value::String("metadata".into()))
                .and_then(|v| v.as_mapping())
                .and_then(|m| m.get(&Value::String("name".into())))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
            namespace: mapping
                .get(&Value::String("metadata".into()))
                .and_then(|v| v.as_mapping())
                .and_then(|m| m.get(&Value::String("namespace".into())))
                .and_then(|v| v.as_str())
                .map(String::from),
            selector: None,
            pod_labels: None,
            configmap_refs: Vec::new(),
            secret_refs: Vec::new(),
            source_file: PathBuf::from("test.yaml"),
            raw: value,
            lint_skip: Vec::new(),
        }
    }

    #[test]
    fn test_crd_schema_missing_required_field() {
        let crd = make_resource(
            r#"
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: widgets.example.io
spec:
  group: example.io
  names:
    kind: Widget
  versions:
    - name: v1
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required:
                - provider
              properties:
                provider:
                  type: string
                config:
                  type: object
"#,
        );

        // Resource missing the required "provider" field
        let resource = make_resource(
            r#"
apiVersion: example.io/v1
kind: Widget
metadata:
  name: test-widget
  namespace: default
spec:
  config: {}
"#,
        );

        let diags = check_crd_schema(&[crd, resource], "test-cluster");
        assert_eq!(diags.len(), 1);
        assert_eq!(diags[0].severity, Severity::Error);
        assert!(diags[0].message.contains("missing required field 'provider'"));
        assert!(diags[0].message.contains("spec"));
    }

    #[test]
    fn test_crd_schema_valid_resource() {
        let crd = make_resource(
            r#"
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: widgets.example.io
spec:
  group: example.io
  names:
    kind: Widget
  versions:
    - name: v1
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required:
                - provider
              properties:
                provider:
                  type: string
"#,
        );

        let resource = make_resource(
            r#"
apiVersion: example.io/v1
kind: Widget
metadata:
  name: test-widget
  namespace: default
spec:
  provider: aws
"#,
        );

        let diags = check_crd_schema(&[crd, resource], "test-cluster");
        assert!(diags.is_empty());
    }

    #[test]
    fn test_crd_schema_invalid_enum() {
        let crd = make_resource(
            r#"
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: widgets.example.io
spec:
  group: example.io
  names:
    kind: Widget
  versions:
    - name: v1
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                mode:
                  type: string
                  enum:
                    - fast
                    - slow
"#,
        );

        let resource = make_resource(
            r#"
apiVersion: example.io/v1
kind: Widget
metadata:
  name: test-widget
spec:
  mode: invalid
"#,
        );

        let diags = check_crd_schema(&[crd, resource], "test-cluster");
        assert_eq!(diags.len(), 1);
        assert_eq!(diags[0].severity, Severity::Error);
        assert!(diags[0].message.contains("not in allowed values"));
    }

    #[test]
    fn test_crd_schema_type_mismatch() {
        let crd = make_resource(
            r#"
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: widgets.example.io
spec:
  group: example.io
  names:
    kind: Widget
  versions:
    - name: v1
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                replicas:
                  type: integer
"#,
        );

        let resource = make_resource(
            r#"
apiVersion: example.io/v1
kind: Widget
metadata:
  name: test-widget
spec:
  replicas: "not-a-number"
"#,
        );

        let diags = check_crd_schema(&[crd, resource], "test-cluster");
        assert_eq!(diags.len(), 1);
        assert_eq!(diags[0].severity, Severity::Warning);
        assert!(diags[0].message.contains("expected type 'integer'"));
    }
}


//! Lint check implementations
//!
//! Each check is a pure function that takes resources and metadata,
//! returning a list of diagnostics.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;

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
        for cm_ref in &r.configmap_refs {
            if !configmaps.contains(&(r.namespace.as_deref(), cm_ref.as_str())) {
                diags.push(Diagnostic {
                    severity: Severity::Warning,
                    check: "reference",
                    cluster: cluster.to_string(),
                    file: r.source_file.clone(),
                    resource: r.display_id(),
                    message: format!("references ConfigMap '{}' which does not exist", cm_ref),
                });
            }
        }
        for secret_ref in &r.secret_refs {
            if !secrets.contains(&(r.namespace.as_deref(), secret_ref.as_str())) {
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
    }

    diags
}

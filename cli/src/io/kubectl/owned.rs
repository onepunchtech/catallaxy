//! Ask a cluster which resources say this lab owns them.
//!
//! Decides nothing. Every judgement about what the answer means lives in
//! `domain::prune`, which is pure and testable without a cluster.

use anyhow::{Context, Result};

use crate::domain::provenance;
use crate::domain::prune::{LiveResource, ResourceKey};

/// Kinds that are never worth listing: they exist in enormous numbers, are
/// owned by a controller rather than by us, and inherit our labels from the
/// thing that created them. Deleting one directly achieves nothing because
/// its owner recreates it. Plural, as `kubectl api-resources -o name` prints
/// them, which is not the kind: `podmonitors` must survive a `pods` filter.
const DERIVED_KINDS: [&str; 5] = [
    "pods",
    "replicasets",
    "endpoints",
    "endpointslices",
    "events",
];

/// Every listable, deletable kind the cluster serves.
///
/// Discovered rather than hardcoded: a lab's CRDs are exactly what a
/// hardcoded list would miss, and a floe that stopped being declared is
/// usually the one that owned the custom resources.
fn listable_kinds(kubectl: &dyn super::Kubectl, kube_context: &str) -> Result<Vec<String>> {
    let out = kubectl
        .stdout_of(
            kube_context,
            &[
                "api-resources",
                "--verbs=list,delete",
                "-o",
                "name",
                "--cached",
            ],
        )
        .context("the cluster did not answer which API resources it serves")?;

    Ok(out
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .map(String::from)
        .collect())
}

/// Whether a controller made this in service of something else.
fn has_owner(metadata: &serde_json::Value) -> bool {
    metadata
        .get("ownerReferences")
        .and_then(|o| o.as_array())
        .is_some_and(|refs| !refs.is_empty())
}

fn is_derived(kind: &str) -> bool {
    DERIVED_KINDS.iter().any(|d| d.eq_ignore_ascii_case(kind))
}

/// Resources across the cluster carrying `catallaxy.io/lab=<lab>`.
///
/// One batched `kubectl get` over every discovered kind. Kinds the server
/// refuses to list are skipped rather than fatal: an aggregated API whose
/// backing service is down would otherwise make a deploy fail on something
/// unrelated to it.
///
/// # Errors
///
/// If the server's listable kinds cannot be read. Once they can, a kind that
/// refuses to list is skipped, so a short result means some kinds did not
/// answer rather than that nothing is labelled.
pub fn owned_by_lab(
    kubectl: &dyn super::Kubectl,
    kube_context: &str,
    lab: &str,
) -> Result<Vec<LiveResource>> {
    let kinds: Vec<String> = listable_kinds(kubectl, kube_context)?
        .into_iter()
        .filter(|k| !is_derived(k.split('.').next().unwrap_or(k)))
        .collect();
    if kinds.is_empty() {
        return Ok(Vec::new());
    }

    let selector = format!("{}={}", provenance::LAB, lab);
    let joined = kinds.join(",");
    let raw = kubectl
        .stdout_of(
            kube_context,
            &[
                "get",
                &joined,
                "--all-namespaces",
                "-l",
                &selector,
                "--ignore-not-found",
                "-o",
                "json",
            ],
        )
        .context("the cluster did not answer which resources carry this lab's label")?;

    Ok(parse_items(&raw))
}

/// The `items` of a `kubectl get -o json` list, as resources with their bundle.
fn parse_items(raw: &str) -> Vec<LiveResource> {
    let Ok(doc) = serde_json::from_str::<serde_json::Value>(raw) else {
        return Vec::new();
    };
    let Some(items) = doc.get("items").and_then(|i| i.as_array()) else {
        return Vec::new();
    };

    items
        .iter()
        .filter_map(|item| {
            let kind = item.get("kind")?.as_str()?;
            let metadata = item.get("metadata")?;

            // Something else's, whatever label it carries. Controllers copy
            // the labels of the object they were told to build onto what they
            // build: cert-manager stamps a Certificate's labels onto its
            // CertificateRequest, and prometheus-operator stamps a Prometheus
            // CR's onto the StatefulSet it creates. Both then read as "this
            // lab's, and not declared", and pruning deleted them seconds after
            // they came up. Kubernetes already records who owns a thing, and
            // deleting the owner takes it with it, so an owned resource is
            // never ours to remove.
            if has_owner(metadata) {
                return None;
            }

            let name = metadata.get("name")?.as_str()?;
            let namespace = metadata
                .get("namespace")
                .and_then(|n| n.as_str())
                .map(str::to_string);
            let bundle = metadata
                .get("labels")
                .and_then(|l| l.get(provenance::BUNDLE))
                .and_then(|b| b.as_str())
                .filter(|b| !b.is_empty())
                .map(str::to_string);
            Some(LiveResource {
                key: ResourceKey {
                    kind: kind.to_string(),
                    namespace,
                    name: name.to_string(),
                },
                bundle,
            })
        })
        .collect()
}

/// # Errors
///
/// If kubectl cannot be spawned. `--ignore-not-found`, so a resource already
/// gone is success, and `--wait=false`, so returning does not mean it is
/// deleted, only that the deletion was accepted.
pub fn delete(kubectl: &dyn super::Kubectl, kube_context: &str, key: &ResourceKey) -> Result<()> {
    let target = format!("{}/{}", key.kind.to_lowercase(), key.name);
    let mut args: Vec<&str> = vec!["delete"];
    if let Some(ns) = &key.namespace {
        args.extend(["-n", ns]);
    }
    args.extend([&target, "--ignore-not-found", "--wait=false"]);
    kubectl
        .run(kube_context, &args)
        .with_context(|| format!("deleting {}", key.describe()))?;
    Ok(())
}

#[cfg(test)]
mod tests {

    /// A controller copies the labels of what it was told to build onto what
    /// it builds, so the child reads as this lab's and undeclared. Pruning it
    /// deletes something that is about to be recreated, and in the meantime
    /// the lab is down.
    #[test]
    fn a_resource_something_else_owns_is_not_ours_to_prune() {
        let raw = r#"{"items":[
          {"kind":"StatefulSet","metadata":{"name":"owned","namespace":"p",
            "ownerReferences":[{"kind":"Prometheus","name":"p"}]}},
          {"kind":"Deployment","metadata":{"name":"ours","namespace":"p"}}
        ]}"#;
        let got = super::parse_items(raw);
        let names: Vec<&str> = got.iter().map(|r| r.key.name.as_str()).collect();
        assert_eq!(names, vec!["ours"]);
    }
    use super::*;

    #[test]
    fn a_listed_resource_carries_its_bundle() {
        let raw = r#"{"items":[
            {"kind":"Deployment","metadata":{"name":"a","namespace":"x",
             "labels":{"catallaxy.io/bundle":"harbor"}}}]}"#;
        let got = parse_items(raw);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].bundle.as_deref(), Some("harbor"));
        assert_eq!(got[0].key.namespace.as_deref(), Some("x"));
    }

    #[test]
    fn a_cluster_scoped_resource_has_no_namespace() {
        let raw = r#"{"items":[
            {"kind":"ClusterRole","metadata":{"name":"admin",
             "labels":{"catallaxy.io/bundle":"gateway"}}}]}"#;
        let got = parse_items(raw);
        assert_eq!(got[0].key.namespace, None);
    }

    // An empty bundle label is not a bundle named "". The distinction decides
    // whether the resource is judged or reported, so it cannot be collapsed.
    #[test]
    fn a_missing_or_empty_bundle_label_reads_as_absent() {
        let raw = r#"{"items":[
            {"kind":"Secret","metadata":{"name":"a","namespace":"x","labels":{}}},
            {"kind":"Secret","metadata":{"name":"b","namespace":"x",
             "labels":{"catallaxy.io/bundle":""}}}]}"#;
        let got = parse_items(raw);
        assert_eq!(got.len(), 2);
        assert!(got.iter().all(|r| r.bundle.is_none()));
    }

    // kubectl prints nothing when nothing matches, and an empty list is not
    // the same as a parse failure, but both must yield no candidates rather
    // than a panic.
    #[test]
    fn nothing_to_parse_yields_no_resources() {
        assert!(parse_items("").is_empty());
        assert!(parse_items(r#"{"items":[]}"#).is_empty());
        assert!(parse_items("not json at all").is_empty());
    }

    #[test]
    fn pods_and_replicasets_are_not_worth_listing() {
        assert!(is_derived("pods"));
        assert!(is_derived("replicasets"));
        assert!(is_derived("endpointslices"));
        assert!(!is_derived("deployments"));
        assert!(!is_derived("podmonitors"));
    }
}

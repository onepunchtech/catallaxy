//! What to delete when the declaration stops naming something.
//!
//! `lab up` applies a subset of what a cluster declares. For an argocd lab it
//! applies only the install-target set and argocd owns the rest, but both
//! carry the same `catallaxy.io/lab` label. So "labelled with this lab and not
//! in what I just applied" is not the same question as "no longer declared",
//! and answering the first would delete everything argocd manages.
//!
//! Two facts separate them. `.declared-bundles` lists every bundle the cluster
//! declares, whoever applies it. The applied tree says which bundles this run
//! is responsible for. A resource is only pruned when its bundle is gone from
//! the declaration entirely, or when it belongs to a bundle this run applied
//! and the run did not apply it.
//!
//! This makes `catallaxy.io/bundle` the answer to "who applies this", which is
//! why an argocd Application does not carry the bundle it points at. The
//! bundle's own resources are applied by argocd from git and the Application by
//! the root app-of-apps, so labelling it with the bundle it names read as a
//! resource dropped from a bundle the bootstrap had just applied, and one `lab
//! up` deleted the whole gitops layer. Objects a strategy uses to deliver
//! bundles get a bundle of their own instead, `deliveryBundle` in the render.
//!
//! Storage is never deleted, only reported. A PersistentVolumeClaim removed
//! from a declaration is far more likely to be a mistake than an instruction,
//! and the cost of being wrong is asymmetric: a lab that comes back finds its
//! data, and a lab that is really gone needs one deliberate command.

use std::collections::BTreeSet;

/// Kinds whose deletion destroys data rather than a running process.
const STORAGE_KINDS: [&str; 2] = ["PersistentVolumeClaim", "PersistentVolume"];

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct ResourceKey {
    pub kind: String,
    pub namespace: Option<String>,
    pub name: String,
}

impl ResourceKey {
    pub fn new(kind: &str, namespace: Option<&str>, name: &str) -> Self {
        ResourceKey {
            kind: kind.to_string(),
            namespace: namespace.map(str::to_string),
            name: name.to_string(),
        }
    }

    pub fn describe(&self) -> String {
        match &self.namespace {
            Some(ns) => format!("{ns}/{}/{}", self.kind.to_lowercase(), self.name),
            None => format!("{}/{}", self.kind.to_lowercase(), self.name),
        }
    }

    fn is_storage(&self) -> bool {
        STORAGE_KINDS.contains(&self.kind.as_str())
    }
}

/// A resource the cluster reports as carrying this lab's label.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LiveResource {
    pub key: ResourceKey,
    /// The `catallaxy.io/bundle` label. Absent means something applied it with
    /// a lab label and no bundle, which this refuses to judge.
    pub bundle: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PrunePlan {
    /// Safe to delete: the declaration no longer names them.
    pub delete: Vec<ResourceKey>,
    /// No longer declared, but deleting them would destroy data.
    pub orphaned_storage: Vec<ResourceKey>,
    /// Carry a lab label and no bundle label, so ownership cannot be decided.
    pub unattributed: Vec<ResourceKey>,
}

impl PrunePlan {
    pub fn is_empty(&self) -> bool {
        self.delete.is_empty() && self.orphaned_storage.is_empty() && self.unattributed.is_empty()
    }
}

pub struct PruneInputs<'a> {
    pub live: &'a [LiveResource],
    /// Every bundle the cluster declares, from `.declared-bundles`.
    pub declared_bundles: &'a BTreeSet<String>,
    /// The bundles this run applied, from `.wave-meta`.
    pub applied_bundles: &'a BTreeSet<String>,
    /// Every resource this run applied.
    pub applied: &'a BTreeSet<ResourceKey>,
}

/// Whether the applied tree names this resource.
///
/// The cluster is the authority on whether a kind is namespaced, not the
/// manifest. Helm charts routinely stamp `metadata.namespace` on cluster-
/// scoped resources -- traefik's chart does it to its own GatewayClass -- and
/// the API server drops it. Comparing keys verbatim then reads the resource as
/// one the declaration no longer names, and deletes something still declared.
///
/// So when the cluster reports no namespace, match on kind and name alone.
/// There is only one cluster-scoped object with a given kind and name, so if
/// the applied tree names that pair at all, this run applied it.
fn was_applied(applied: &BTreeSet<ResourceKey>, live: &ResourceKey) -> bool {
    if live.namespace.is_some() {
        return applied.contains(live);
    }
    applied
        .iter()
        .any(|a| a.kind == live.kind && a.name == live.name)
}

pub fn plan_prune(inputs: PruneInputs<'_>) -> PrunePlan {
    let mut plan = PrunePlan::default();

    for resource in inputs.live {
        let Some(bundle) = &resource.bundle else {
            plan.unattributed.push(resource.key.clone());
            continue;
        };

        let gone_from_declaration = !inputs.declared_bundles.contains(bundle);
        let dropped_from_a_bundle_we_applied =
            inputs.applied_bundles.contains(bundle) && !was_applied(inputs.applied, &resource.key);

        if !(gone_from_declaration || dropped_from_a_bundle_we_applied) {
            continue;
        }

        if resource.key.is_storage() {
            plan.orphaned_storage.push(resource.key.clone());
        } else {
            plan.delete.push(resource.key.clone());
        }
    }

    plan.delete.sort();
    plan.orphaned_storage.sort();
    plan.unattributed.sort();
    plan
}

#[cfg(test)]
mod tests {
    use super::*;

    fn set(items: &[&str]) -> BTreeSet<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    fn live(kind: &str, name: &str, bundle: Option<&str>) -> LiveResource {
        LiveResource {
            key: ResourceKey::new(kind, Some("app"), name),
            bundle: bundle.map(str::to_string),
        }
    }

    fn plan(live: &[LiveResource], declared: &[&str], applied_bundles: &[&str]) -> PrunePlan {
        let applied = BTreeSet::new();
        plan_prune(PruneInputs {
            live,
            declared_bundles: &set(declared),
            applied_bundles: &set(applied_bundles),
            applied: &applied,
        })
    }

    #[test]
    fn a_bundle_the_declaration_dropped_is_deleted() {
        let p = plan(
            &[live("Deployment", "harbor", Some("harbor"))],
            &["gateway"],
            &["gateway"],
        );
        assert_eq!(
            p.delete,
            vec![ResourceKey::new("Deployment", Some("app"), "harbor")]
        );
    }

    // The case that makes this more than a set difference. An argocd lab
    // applies its install-target set through `lab up` and argocd applies the
    // rest, so most declared bundles are absent from what the run applied.
    #[test]
    fn a_declared_bundle_this_run_did_not_apply_is_left_alone() {
        let p = plan(
            &[live("Deployment", "grafana", Some("grafana"))],
            &["grafana", "cert-manager"],
            &["cert-manager"],
        );
        assert!(p.is_empty(), "{p:?}");
    }

    #[test]
    fn a_resource_dropped_from_a_bundle_this_run_applied_is_deleted() {
        let applied: BTreeSet<ResourceKey> =
            [ResourceKey::new("Service", Some("app"), "kept")].into();
        let p = plan_prune(PruneInputs {
            live: &[
                live("Service", "kept", Some("gateway")),
                live("Service", "removed", Some("gateway")),
            ],
            declared_bundles: &set(&["gateway"]),
            applied_bundles: &set(&["gateway"]),
            applied: &applied,
        });
        assert_eq!(
            p.delete,
            vec![ResourceKey::new("Service", Some("app"), "removed")]
        );
    }

    #[test]
    fn storage_left_by_a_dropped_bundle_is_reported_and_kept() {
        let p = plan(
            &[
                live("PersistentVolumeClaim", "harbor-data", Some("harbor")),
                live("Deployment", "harbor", Some("harbor")),
            ],
            &[],
            &[],
        );
        assert_eq!(
            p.orphaned_storage,
            vec![ResourceKey::new(
                "PersistentVolumeClaim",
                Some("app"),
                "harbor-data"
            )]
        );
        assert_eq!(
            p.delete,
            vec![ResourceKey::new("Deployment", Some("app"), "harbor")]
        );
    }

    #[test]
    fn a_persistent_volume_is_storage_even_though_it_is_cluster_scoped() {
        let p = plan_prune(PruneInputs {
            live: &[LiveResource {
                key: ResourceKey::new("PersistentVolume", None, "pv-1"),
                bundle: Some("gone".into()),
            }],
            declared_bundles: &set(&[]),
            applied_bundles: &set(&[]),
            applied: &BTreeSet::new(),
        });
        assert!(p.delete.is_empty());
        assert_eq!(p.orphaned_storage.len(), 1);
    }

    // Something wearing the lab label with no bundle label was not put there
    // by a render this understands, so guessing either way is wrong.
    #[test]
    fn a_resource_with_no_bundle_label_is_reported_not_deleted() {
        let p = plan(
            &[live("Secret", "mystery", None)],
            &["gateway"],
            &["gateway"],
        );
        assert!(p.delete.is_empty());
        assert_eq!(
            p.unattributed,
            vec![ResourceKey::new("Secret", Some("app"), "mystery")]
        );
    }

    #[test]
    fn a_cluster_that_matches_its_declaration_prunes_nothing() {
        let applied: BTreeSet<ResourceKey> =
            [ResourceKey::new("Deployment", Some("app"), "podinfo")].into();
        let p = plan_prune(PruneInputs {
            live: &[live("Deployment", "podinfo", Some("custom-podinfo"))],
            declared_bundles: &set(&["custom-podinfo"]),
            applied_bundles: &set(&["custom-podinfo"]),
            applied: &applied,
        });
        assert!(p.is_empty(), "{p:?}");
    }

    // Found by running it: traefik's chart sets metadata.namespace on its own
    // GatewayClass, which is cluster-scoped, so the manifest says kube-system
    // and the API server says nothing. Comparing keys verbatim deleted a
    // GatewayClass whose floe was still enabled.
    #[test]
    fn a_cluster_scoped_resource_matches_however_the_manifest_scoped_it() {
        let applied: BTreeSet<ResourceKey> = [ResourceKey::new(
            "GatewayClass",
            Some("kube-system"),
            "traefik",
        )]
        .into();
        let p = plan_prune(PruneInputs {
            live: &[LiveResource {
                key: ResourceKey::new("GatewayClass", None, "traefik"),
                bundle: Some("gateway-controller".into()),
            }],
            declared_bundles: &set(&["gateway-controller"]),
            applied_bundles: &set(&["gateway-controller"]),
            applied: &applied,
        });
        assert!(p.is_empty(), "{p:?}");
    }

    // And the leniency is bounded: it must not make a genuinely dropped
    // cluster-scoped resource look applied.
    #[test]
    fn a_cluster_scoped_resource_nothing_applied_is_still_deleted() {
        let applied: BTreeSet<ResourceKey> = [ResourceKey::new("ClusterRole", None, "kept")].into();
        let p = plan_prune(PruneInputs {
            live: &[LiveResource {
                key: ResourceKey::new("ClusterRole", None, "removed"),
                bundle: Some("gateway".into()),
            }],
            declared_bundles: &set(&["gateway"]),
            applied_bundles: &set(&["gateway"]),
            applied: &applied,
        });
        assert_eq!(
            p.delete,
            vec![ResourceKey::new("ClusterRole", None, "removed")]
        );
    }

    // A namespaced resource is still matched exactly, so the same name in two
    // namespaces stays two resources.
    #[test]
    fn a_namespaced_resource_still_matches_on_its_namespace() {
        let applied: BTreeSet<ResourceKey> = [ResourceKey::new("Service", Some("a"), "svc")].into();
        let p = plan_prune(PruneInputs {
            live: &[LiveResource {
                key: ResourceKey::new("Service", Some("b"), "svc"),
                bundle: Some("gateway".into()),
            }],
            declared_bundles: &set(&["gateway"]),
            applied_bundles: &set(&["gateway"]),
            applied: &applied,
        });
        assert_eq!(
            p.delete,
            vec![ResourceKey::new("Service", Some("b"), "svc")]
        );
    }

    #[test]
    fn nothing_live_means_nothing_to_do() {
        assert!(plan(&[], &["gateway"], &["gateway"]).is_empty());
    }

    #[test]
    fn a_namespaced_resource_reads_as_namespace_kind_name() {
        assert_eq!(
            ResourceKey::new("Deployment", Some("harbor"), "core").describe(),
            "harbor/deployment/core"
        );
        assert_eq!(
            ResourceKey::new("ClusterRole", None, "admin").describe(),
            "clusterrole/admin"
        );
    }
}

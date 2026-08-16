mod crossplane;
mod diagnostics;
mod finalizers;
mod kubeconfig;
mod run;

pub use crossplane::*;
pub use diagnostics::*;
pub use finalizers::*;
pub use kubeconfig::*;
pub use run::*;

#[cfg(test)]
mod tests {
    use super::*;

    fn managed(items: serde_json::Value) -> serde_json::Value {
        serde_json::json!({ "items": items })
    }

    fn managed_item(
        kind: &str,
        api_version: &str,
        name: &str,
        external: Option<&str>,
    ) -> serde_json::Value {
        serde_json::json!({
            "kind": kind,
            "apiVersion": api_version,
            "metadata": {
                "name": name,
                "annotations": match external {
                    Some(e) => serde_json::json!({ "crossplane.io/external-name": e }),
                    None => serde_json::json!({}),
                },
            }
        })
    }

    #[test]
    fn a_managed_resource_becomes_a_group_qualified_target() {
        let json = managed(serde_json::json!([managed_item(
            "Cluster",
            "kubernetes.digitalocean.crossplane.io/v1alpha1",
            "prod",
            Some("uuid-1"),
        )]));

        let (targets, skipped) = external_name_targets(&json);

        assert_eq!(skipped, 0);
        assert_eq!(targets.len(), 1);
        assert_eq!(
            targets[0].resource,
            "cluster.kubernetes.digitalocean.crossplane.io/prod"
        );
        assert_eq!(targets[0].external_name, "uuid-1");
    }

    #[test]
    fn a_resource_with_no_external_name_is_counted_as_skipped() {
        let json = managed(serde_json::json!([
            managed_item("Cluster", "x.io/v1", "a", None),
            managed_item("Cluster", "x.io/v1", "b", Some("")),
            managed_item("Cluster", "x.io/v1", "c", Some("uuid")),
        ]));

        let (targets, skipped) = external_name_targets(&json);

        assert_eq!(skipped, 2);
        assert_eq!(targets.len(), 1);
    }

    #[test]
    fn a_resource_missing_its_kind_or_group_is_dropped_without_counting() {
        let json = managed(serde_json::json!([
            managed_item("", "x.io/v1", "a", Some("uuid")),
            managed_item("Cluster", "v1", "b", Some("uuid")),
        ]));

        let (targets, skipped) = external_name_targets(&json);

        assert!(targets.is_empty());
        assert_eq!(
            skipped, 0,
            "skipped counts resources with nothing to copy, not ones we cannot address"
        );
    }

    #[test]
    fn a_namespaced_resource_carries_its_namespace_into_the_arguments() {
        let mut item = managed_item("Bucket", "s3.aws.io/v1", "b", Some("uuid"));
        item["metadata"]["namespace"] = serde_json::json!("team");

        let (targets, _) = external_name_targets(&managed(serde_json::json!([item])));
        let args = targets[0].annotate_args("target-ctx");

        assert!(args.contains(&"-n".to_string()), "{args:?}");
        assert!(args.contains(&"team".to_string()), "{args:?}");
        assert!(args.contains(&"--overwrite".to_string()), "{args:?}");
        assert!(
            args.contains(&"crossplane.io/external-name=uuid".to_string()),
            "{args:?}"
        );
    }

    #[test]
    fn a_response_with_no_items_yields_nothing() {
        assert_eq!(
            external_name_targets(&serde_json::json!({})),
            (Vec::new(), 0)
        );
    }

    #[test]
    fn a_duration_parses_with_any_of_the_kubectl_suffixes() {
        assert_eq!(
            parse_timeout("30s"),
            Some(std::time::Duration::from_secs(30))
        );
        assert_eq!(
            parse_timeout("10m"),
            Some(std::time::Duration::from_secs(600))
        );
        assert_eq!(
            parse_timeout("1h"),
            Some(std::time::Duration::from_secs(3600))
        );
        assert_eq!(
            parse_timeout("45"),
            Some(std::time::Duration::from_secs(45))
        );
    }

    #[test]
    fn a_duration_it_cannot_parse_is_not_silently_ten_minutes() {
        for bad in ["", "soon", "5ms", "-3s", "1.5h"] {
            assert_eq!(parse_timeout(bad), None, "{bad} must not parse");
        }
    }

    #[test]
    fn a_provider_without_a_healthy_condition_is_named() {
        let providers = serde_json::json!({
            "items": [
                {
                    "metadata": { "name": "provider-aws" },
                    "status": { "conditions": [ { "type": "Healthy", "status": "True" } ] }
                },
                {
                    "metadata": { "name": "provider-digitalocean" },
                    "status": { "conditions": [ { "type": "Healthy", "status": "False" } ] }
                },
                { "metadata": { "name": "provider-nostatus" } }
            ]
        });

        assert_eq!(
            unhealthy_provider_names(&providers),
            vec!["provider-digitalocean", "provider-nostatus"],
            "the timeout message must be able to name what it waited on"
        );
    }

    #[test]
    fn a_crossplane_finalizer_is_never_stripped() {
        for kind in [
            "clusters.kubernetes.digitalocean.crossplane.io",
            "instances.ec2.aws.upbound.io",
        ] {
            assert!(
                is_crossplane_managed(kind),
                "{kind} owns a cloud resource, so stripping its finalizer orphans it"
            );
        }
        assert!(!is_crossplane_managed("certificates.cert-manager.io"));
    }
}

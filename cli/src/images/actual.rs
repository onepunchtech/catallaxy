//! What a running cluster actually pulled.
//!
//! Rendering a lab says what catallaxy asked for. It cannot say what arrived:
//! an operator creates workloads catallaxy never wrote, so CNPG's Postgres
//! pods, Crossplane's provider pods and a StatefulSet kaniop builds are all
//! invisible to anything that reads manifests, however many paths it reads.
//!
//! A cluster knows. This reads the answer back out of one, which is why it is
//! a discovery aid rather than an authority: it can only report what has
//! already run, so it says nothing about a workload that has not started yet.

use std::collections::BTreeSet;

use serde_json::Value;

/// Every image named by the pods in a `kubectl get pods -A -o json` payload.
///
/// Both the spec and the status are read. The spec is what was asked for, and
/// on a pod that has not started that is all there is; the status carries what
/// the kubelet resolved, which is the same reference except when the spec
/// named a tag that has since moved.
pub fn images_in_pods(payload: &Value) -> BTreeSet<String> {
    let mut out = BTreeSet::new();

    let Some(items) = payload.get("items").and_then(Value::as_array) else {
        return out;
    };

    for pod in items {
        for field in ["containers", "initContainers", "ephemeralContainers"] {
            collect_images(pod.pointer(&format!("/spec/{field}")), &mut out);
        }
        for field in [
            "containerStatuses",
            "initContainerStatuses",
            "ephemeralContainerStatuses",
        ] {
            collect_images(pod.pointer(&format!("/status/{field}")), &mut out);
        }
    }

    out
}

fn collect_images(containers: Option<&Value>, out: &mut BTreeSet<String>) {
    let Some(containers) = containers.and_then(Value::as_array) else {
        return;
    };
    for container in containers {
        if let Some(image) = container.get("image").and_then(Value::as_str)
            && !image.is_empty()
        {
            out.insert(image.to_string());
        }
    }
}

/// What is running that the lab never rendered.
///
/// Comparison is on the reference with any digest dropped, because a kubelet
/// reports what it resolved and the lab renders what it asked for. Treating
/// `nginx:1.27` and `nginx:1.27@sha256:...` as different images would report
/// every image in the cluster as a surprise.
pub fn undeclared<'a>(actual: &'a BTreeSet<String>, rendered: &[String]) -> Vec<&'a str> {
    let known: BTreeSet<&str> = rendered.iter().map(|i| without_digest(i)).collect();
    actual
        .iter()
        .filter(|i| !known.contains(without_digest(i)))
        .map(String::as_str)
        .collect()
}

fn without_digest(image: &str) -> &str {
    match image.split_once('@') {
        Some((before, _)) => before,
        None => image,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn pods(items: Value) -> Value {
        json!({ "items": items })
    }

    #[test]
    fn reads_containers_and_init_containers() {
        let got = images_in_pods(&pods(json!([{
            "spec": {
                "containers": [{ "image": "nginx:1.27" }],
                "initContainers": [{ "image": "busybox:1.36" }],
            }
        }])));
        assert_eq!(
            got.into_iter().collect::<Vec<_>>(),
            vec!["busybox:1.36", "nginx:1.27"]
        );
    }

    // A pod that has not started has no status at all, and it is exactly the
    // pod whose image someone wants to know about.
    #[test]
    fn a_pod_with_no_status_still_reports_its_image() {
        let got = images_in_pods(&pods(json!([{
            "spec": { "containers": [{ "image": "nginx:1.27" }] }
        }])));
        assert_eq!(got.into_iter().collect::<Vec<_>>(), vec!["nginx:1.27"]);
    }

    // The kubelet resolves a tag to whatever it pulled, so the status can
    // name something the spec never did.
    #[test]
    fn the_status_can_name_an_image_the_spec_did_not() {
        let got = images_in_pods(&pods(json!([{
            "spec": { "containers": [{ "image": "nginx:1.27" }] },
            "status": { "containerStatuses": [{ "image": "nginx:1.27@sha256:abc" }] },
        }])));
        assert_eq!(
            got.into_iter().collect::<Vec<_>>(),
            vec!["nginx:1.27", "nginx:1.27@sha256:abc"]
        );
    }

    #[test]
    fn an_empty_or_malformed_payload_is_not_an_error() {
        assert!(images_in_pods(&json!({})).is_empty());
        assert!(images_in_pods(&pods(json!([{ "spec": {} }]))).is_empty());
        assert!(images_in_pods(&pods(json!([{ "spec": { "containers": {} } }]))).is_empty());
    }

    // The whole point: an operator made this pod, so no manifest catallaxy
    // rendered ever mentioned it.
    #[test]
    fn reports_what_the_lab_never_rendered() {
        let actual = images_in_pods(&pods(json!([{
            "spec": { "containers": [
                { "image": "ghcr.io/cloudnative-pg/cloudnative-pg:1.25.0" },
                { "image": "ghcr.io/cloudnative-pg/postgresql:16.4" },
            ] }
        }])));
        let rendered = vec!["ghcr.io/cloudnative-pg/cloudnative-pg:1.25.0".to_string()];
        assert_eq!(
            undeclared(&actual, &rendered),
            vec!["ghcr.io/cloudnative-pg/postgresql:16.4"]
        );
    }

    // A kubelet reports a digest the lab never wrote. Comparing the strings
    // would call every image in the cluster a surprise.
    #[test]
    fn a_resolved_digest_is_not_a_surprise() {
        let actual = images_in_pods(&pods(json!([{
            "status": { "containerStatuses": [{ "image": "nginx:1.27@sha256:abc" }] }
        }])));
        assert!(undeclared(&actual, &["nginx:1.27".to_string()]).is_empty());
    }
}

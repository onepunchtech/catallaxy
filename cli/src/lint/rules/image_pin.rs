use serde_yaml::Value;

use crate::domain::diagnostic::{Diagnostic, Severity};
use crate::images::ImageRef;

use crate::lint::manifest::K8sResource;

use super::{CheckContext, CheckRule};

pub struct ImagePin;

impl CheckRule for ImagePin {
    fn name(&self) -> &'static str {
        "image-pin"
    }
    fn check(&self, ctx: &CheckContext<'_>) -> Vec<Diagnostic> {
        check(ctx.resources, ctx.cluster, ctx.images)
    }
}

fn yaml_get<'a>(val: &'a Value, keys: &[&str]) -> Option<&'a Value> {
    let mut current = val;
    for key in keys {
        current = current.get(Value::String(key.to_string()))?;
    }
    Some(current)
}

fn extract_images(resource: &K8sResource) -> Vec<String> {
    let mut images = Vec::new();

    let containers_paths: &[&[&str]] = &[
        &["spec", "template", "spec", "containers"],
        &["spec", "template", "spec", "initContainers"],
        &["spec", "containers"],
        &["spec", "initContainers"],
        &[
            "spec",
            "jobTemplate",
            "spec",
            "template",
            "spec",
            "containers",
        ],
        // A CronJob's init containers. Missing here while the scrape that
        // feeds `cata images lock` had it, so those images were lockable and
        // unlintable: the lock rewrote a digest into something requireDigest
        // could not have flagged.
        &[
            "spec",
            "jobTemplate",
            "spec",
            "template",
            "spec",
            "initContainers",
        ],
    ];

    for path in containers_paths {
        if let Some(containers) = yaml_get(&resource.raw, path).and_then(|v| v.as_sequence()) {
            for container in containers {
                if let Some(image) = container
                    .get(Value::String("image".into()))
                    .and_then(|v| v.as_str())
                {
                    images.push(image.to_string());
                }
            }
        }
    }

    images
}

fn check(resources: &[K8sResource], cluster: &str, policy: &super::ImagePolicy) -> Vec<Diagnostic> {
    let mut diags = Vec::new();

    for r in resources {
        if r.has_lint_skip("image-pin") {
            continue;
        }

        let images = extract_images(r);
        for image in &images {
            let parsed = ImageRef::parse(image);

            // An untagged image resolves to `latest` and is mutable in
            // exactly the same way, so it is the same finding. It used to be
            // silent because the tag was simply absent.
            if parsed.tag.as_deref() == Some("latest") || parsed.tag.is_none() {
                diags.push(Diagnostic {
                    severity: Severity::Warning,
                    check: "image-pin",
                    cluster: cluster.to_string(),
                    file: r.source_file.clone(),
                    resource: r.display_id(),
                    message: format!("resolves to the mutable ':latest' tag: {image}"),
                });
            }

            if policy.require_digest && parsed.digest.is_none() {
                diags.push(Diagnostic {
                    severity: Severity::Error,
                    check: "image-pin",
                    cluster: cluster.to_string(),
                    file: r.source_file.clone(),
                    resource: r.display_id(),
                    message: format!("image not pinned by digest: {image}"),
                });
            }

            if !policy.allowed_registries.is_empty()
                && !policy.allowed_registries.contains(&parsed.registry)
            {
                diags.push(Diagnostic {
                    severity: Severity::Warning,
                    check: "image-pin",
                    cluster: cluster.to_string(),
                    file: r.source_file.clone(),
                    resource: r.display_id(),
                    message: format!(
                        "image from unapproved registry '{}': {image}",
                        parsed.registry
                    ),
                });
            }
        }
    }

    diags
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lint::ImagePolicy;
    use crate::lint::rules::test_util::make_resource;

    fn dep_with_image(image: &str) -> K8sResource {
        make_resource(&format!(
            "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: app\n  namespace: apps\nspec:\n  template:\n    metadata:\n      labels:\n        app: app\n    spec:\n      containers:\n      - name: c\n        image: {image}\n"
        ))
    }

    fn policy(require_digest: bool, allowed: &[&str]) -> ImagePolicy {
        ImagePolicy {
            require_digest,
            allowed_registries: allowed.iter().map(|s| s.to_string()).collect(),
        }
    }

    // Only `spec.template.spec.containers` had a test, so the other five
    // paths were carried by nothing. One is what let a CronJob's init
    // containers go unlinted while the lock rewrote them.
    #[test]
    fn every_container_path_is_read() {
        let cases: &[(&str, &str)] = &[
            (
                "pod containers",
                "apiVersion: v1\nkind: Pod\nmetadata:\n  name: p\nspec:\n  containers:\n  - name: c\n    image: a:latest\n",
            ),
            (
                "pod initContainers",
                "apiVersion: v1\nkind: Pod\nmetadata:\n  name: p\nspec:\n  initContainers:\n  - name: c\n    image: a:latest\n",
            ),
            (
                "template initContainers",
                "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: d\nspec:\n  template:\n    spec:\n      initContainers:\n      - name: c\n        image: a:latest\n",
            ),
            (
                "cronjob containers",
                "apiVersion: batch/v1\nkind: CronJob\nmetadata:\n  name: cj\nspec:\n  jobTemplate:\n    spec:\n      template:\n        spec:\n          containers:\n          - name: c\n            image: a:latest\n",
            ),
            (
                "cronjob initContainers",
                "apiVersion: batch/v1\nkind: CronJob\nmetadata:\n  name: cj\nspec:\n  jobTemplate:\n    spec:\n      template:\n        spec:\n          initContainers:\n          - name: c\n            image: a:latest\n",
            ),
        ];

        for (what, yaml) in cases {
            let diags = check(&[make_resource(yaml)], "c", &policy(false, &[]));
            assert!(
                diags.iter().any(|d| d.message.contains("':latest'")),
                "{what}: the image at this path was never read"
            );
        }
    }

    #[test]
    fn latest_tag_always_warns() {
        let r = dep_with_image("nginx:latest");
        let diags = check(&[r], "c", &policy(false, &[]));
        assert!(diags.iter().any(|d| d.message.contains("':latest'")));
    }

    // An untagged image resolves to `latest`, so it is the same mutable
    // reference. It used to pass silently because the tag was absent rather
    // than being the string "latest".
    #[test]
    fn an_untagged_image_warns_like_latest() {
        let r = dep_with_image("nginx");
        let diags = check(&[r], "c", &policy(false, &[]));
        assert!(
            diags.iter().any(|d| d.message.contains("':latest'")),
            "an untagged image is as mutable as a :latest one"
        );
    }

    #[test]
    fn tagged_image_passes_when_no_digest_required() {
        let r = dep_with_image("nginx:1.25.3");
        assert!(check(&[r], "c", &policy(false, &[])).is_empty());
    }

    #[test]
    fn digest_requirement_flags_untagged_image() {
        let r = dep_with_image("nginx:1.25.3");
        let diags = check(&[r], "c", &policy(true, &[]));
        assert!(
            diags.iter().any(
                |d| d.severity == Severity::Error && d.message.contains("not pinned by digest")
            )
        );
    }

    #[test]
    fn image_with_digest_satisfies_require_digest() {
        let r = dep_with_image("nginx:1.25.3@sha256:abc123");
        assert!(check(&[r], "c", &policy(true, &[])).is_empty());
    }

    #[test]
    fn allowed_registry_passes() {
        let r = dep_with_image("registry.example.com/app:v1");
        assert!(check(&[r], "c", &policy(false, &["registry.example.com"])).is_empty());
    }

    #[test]
    fn disallowed_registry_warns() {
        let r = dep_with_image("docker.io/nginx:1.25.3");
        let diags = check(&[r], "c", &policy(false, &["registry.example.com"]));
        assert!(
            diags
                .iter()
                .any(|d| d.message.contains("unapproved registry"))
        );
    }

    #[test]
    fn lint_skip_annotation_disables_check() {
        let r = make_resource(
            "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: app\n  namespace: apps\n  annotations:\n    catallaxy.io/lint-skip: image-pin\nspec:\n  template:\n    metadata:\n      labels:\n        app: app\n    spec:\n      containers:\n      - name: c\n        image: nginx:latest\n",
        );
        assert!(check(&[r], "c", &policy(false, &[])).is_empty());
    }
}

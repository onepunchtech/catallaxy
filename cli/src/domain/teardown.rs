use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResourceRef {
    pub kind: String,
    pub name: String,
}

impl ResourceRef {
    pub fn new(kind: impl Into<String>, name: impl Into<String>) -> Self {
        Self {
            kind: kind.into(),
            name: name.into(),
        }
    }

    pub fn qualified(&self) -> String {
        format!("{}/{}", self.kind, self.name)
    }
}

impl std::fmt::Display for ResourceRef {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}/{}", self.kind, self.name)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StepFailure {
    pub step: &'static str,
    pub detail: String,
    pub resource: Option<ResourceRef>,
}

impl StepFailure {
    pub fn new(step: &'static str, detail: impl Into<String>) -> Self {
        Self {
            step,
            detail: detail.into(),
            resource: None,
        }
    }

    pub fn on_resource(
        step: &'static str,
        kind: impl Into<String>,
        name: impl Into<String>,
        detail: impl Into<String>,
    ) -> Self {
        Self {
            step,
            detail: detail.into(),
            resource: Some(ResourceRef {
                kind: kind.into(),
                name: name.into(),
            }),
        }
    }

    pub fn concerns(&self, resource: &ResourceRef) -> bool {
        self.resource.as_ref().is_some_and(|r| r == resource)
    }

    pub fn describe(&self) -> String {
        match &self.resource {
            Some(r) => format!("{} {}/{}: {}", self.step, r.kind, r.name, self.detail),
            None => format!("{}: {}", self.step, self.detail),
        }
    }
}

pub fn report(failures: &[StepFailure], rescue_hints: &BTreeMap<String, String>) -> Option<String> {
    if failures.is_empty() {
        return None;
    }

    let mut out = format!(
        "Teardown finished with {} unresolved failure(s):\n",
        failures.len()
    );
    for f in failures {
        out.push_str(&format!("  - {}\n", f.describe()));
    }

    let hints = matching_hints(failures, rescue_hints);
    if !hints.is_empty() {
        out.push_str("\nCloud resources may still exist. The lab declares these rescue hints:\n");
        for (kind, hint) in hints {
            out.push_str(&format!("  {kind}\n    {hint}\n"));
        }
    }

    Some(out)
}

fn matching_hints<'a>(
    failures: &[StepFailure],
    rescue_hints: &'a BTreeMap<String, String>,
) -> Vec<(&'a String, &'a String)> {
    rescue_hints
        .iter()
        .filter(|(kind, _)| {
            failures
                .iter()
                .any(|f| f.resource.as_ref().is_some_and(|r| &&r.kind == kind))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hints() -> BTreeMap<String, String> {
        BTreeMap::from([
            (
                "clusters.kubernetes.digitalocean.crossplane.io".to_string(),
                "doctl kubernetes cluster delete <id>".to_string(),
            ),
            (
                "clusters.eks.aws.upbound.io".to_string(),
                "aws eks delete-cluster --name <name>".to_string(),
            ),
        ])
    }

    #[test]
    fn a_clean_teardown_reports_nothing() {
        assert_eq!(report(&[], &hints()), None);
    }

    #[test]
    fn a_leaked_resource_pulls_in_only_its_own_hint() {
        let failures = vec![StepFailure::on_resource(
            "delete-managed-resource",
            "clusters.kubernetes.digitalocean.crossplane.io",
            "workload",
            "still present after timeout",
        )];

        let out = report(&failures, &hints()).expect("failures must produce a report");

        assert!(out.contains("doctl kubernetes cluster delete"), "{out}");
        assert!(!out.contains("aws eks delete-cluster"), "{out}");
        assert!(
            out.contains(
                "delete-managed-resource clusters.kubernetes.digitalocean.crossplane.io/workload"
            ),
            "{out}"
        );
    }

    #[test]
    fn a_failure_without_a_resource_still_reports() {
        let failures = vec![StepFailure::new("run-script", "binary not realized")];

        let out = report(&failures, &hints()).expect("failures must produce a report");

        assert!(out.contains("run-script: binary not realized"), "{out}");
        assert!(!out.contains("rescue hints"), "{out}");
    }

    #[test]
    fn concerns_matches_only_the_same_resource() {
        let f = StepFailure::on_resource("delete-managed-resource", "clusters.x.io", "a", "boom");

        assert!(f.concerns(&ResourceRef::new("clusters.x.io", "a")));
        assert!(!f.concerns(&ResourceRef::new("clusters.x.io", "b")));
        assert!(!f.concerns(&ResourceRef::new("clusters.y.io", "a")));
    }
}

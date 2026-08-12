use std::collections::HashSet;
use std::path::PathBuf;

use crate::domain::diagnostic::{Diagnostic, Severity};
use crate::domain::plan::{PlannedStep, StepParams};

use super::{LabCheckContext, LabCheckRule};

pub struct Plan;

impl LabCheckRule for Plan {
    fn name(&self) -> &'static str {
        "plan"
    }
    fn check(&self, ctx: &LabCheckContext<'_>) -> Vec<Diagnostic> {
        let known: HashSet<&str> = ctx
            .metadata
            .cluster_names
            .iter()
            .map(String::as_str)
            .collect();

        let mut diags = Vec::new();
        diags.extend(check_cluster_refs(ctx.deployment_plan, &known));
        diags.extend(check_duplicate_create(ctx.deployment_plan));
        diags.extend(check_secret_copy_ordering(ctx.deployment_plan));
        diags
    }
}

fn check_cluster_refs(plan: &[PlannedStep], known: &HashSet<&str>) -> Vec<Diagnostic> {
    let mut diags = Vec::new();
    for (idx, step) in plan.iter().enumerate() {
        for (field, cluster) in step.params.cluster_refs() {
            if !known.contains(cluster) {
                diags.push(diag(
                    Severity::Error,
                    &format!("step[{}]", idx),
                    format!(
                        "plan step '{}' {} references unknown cluster '{}'",
                        step_kind(step),
                        field,
                        cluster,
                    ),
                ));
            }
        }
    }
    diags
}

fn check_duplicate_create(plan: &[PlannedStep]) -> Vec<Diagnostic> {
    let mut seen: HashSet<&str> = HashSet::new();
    let mut diags = Vec::new();
    for step in plan {
        if let StepParams::CreateCluster { name, .. } = &step.params
            && !seen.insert(name.as_str())
        {
            diags.push(diag(
                Severity::Error,
                name,
                format!("cluster '{}' has more than one create-cluster step", name),
            ));
        }
    }
    diags
}

fn check_secret_copy_ordering(plan: &[PlannedStep]) -> Vec<Diagnostic> {
    let mut created: HashSet<&str> = HashSet::new();
    let mut diags = Vec::new();

    let ever_created: HashSet<&str> = plan
        .iter()
        .filter_map(|s| match &s.params {
            StepParams::CreateCluster { name, .. } => Some(name.as_str()),
            _ => None,
        })
        .collect();

    for step in plan {
        if let StepParams::CreateCluster { name, .. } = &step.params {
            created.insert(name.as_str());
        }
        if let StepParams::CrossClusterSecretCopy {
            name,
            source_cluster,
            target_cluster,
            ..
        } = &step.params
        {
            for endpoint in [source_cluster.as_str(), target_cluster.as_str()] {
                if ever_created.contains(endpoint) && !created.contains(endpoint) {
                    diags.push(diag(
                        Severity::Error,
                        name,
                        format!(
                            "cross-cluster secret '{}' copy scheduled before \
                             cluster '{}' is created",
                            name, endpoint,
                        ),
                    ));
                }
            }
        }
    }
    diags
}

fn step_kind(step: &PlannedStep) -> &'static str {
    step.type_tag()
}

fn diag(severity: Severity, resource: &str, message: String) -> Diagnostic {
    Diagnostic {
        severity,
        check: "plan",
        cluster: "<lab>".to_string(),
        file: PathBuf::new(),
        resource: resource.to_string(),
        message,
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::*;
    use crate::lint::{ImagePolicy, LabMetadata};

    fn meta_with(clusters: Vec<&str>, plan: Vec<PlannedStep>) -> LabMetadata {
        LabMetadata {
            name: "test".into(),
            prefix: "".into(),
            cluster_names: clusters.into_iter().map(String::from).collect(),
            lab_namespaces: HashMap::new(),
            clusters: HashMap::new(),
            images: ImagePolicy::default(),
            lint: Default::default(),
            assertions: vec![],
            warnings: vec![],
            deployment_plan: plan,
        }
    }

    fn run(meta: &LabMetadata) -> Vec<Diagnostic> {
        let by_cluster: HashMap<String, Vec<crate::lint::manifest::K8sResource>> = HashMap::new();
        let ctx = LabCheckContext {
            metadata: meta,
            resources_by_cluster: &by_cluster,
            deployment_plan: &meta.deployment_plan,
        };
        Plan.check(&ctx)
    }

    use crate::lint::rules::test_util::planned_step;

    fn create(name: &str) -> PlannedStep {
        planned_step(
            &format!("create-cluster-{name}"),
            "create-cluster",
            serde_json::json!({ "name": name, "provisioner": "k3d" }),
        )
    }

    fn deploy(target: &str) -> PlannedStep {
        planned_step(
            &format!("deploy-manifests-{target}"),
            "deploy-manifests",
            serde_json::json!({ "target": target }),
        )
    }

    fn copy(name: &str, src: &str, tgt: &str) -> PlannedStep {
        planned_step(
            name,
            "cross-cluster-secret-copy",
            serde_json::json!({
                "name": name,
                "sourceCluster": src,
                "sourceNamespace": "ns",
                "sourceSecret": "sec",
                "targetCluster": tgt,
                "targetNamespace": "ns",
                "targetSecret": "sec",
            }),
        )
    }

    #[test]
    fn well_formed_plan_is_silent() {
        let meta = meta_with(
            vec!["hub", "spoke"],
            vec![
                create("hub"),
                create("spoke"),
                deploy("hub"),
                deploy("spoke"),
            ],
        );
        assert!(run(&meta).is_empty());
    }

    #[test]
    fn unknown_target_cluster_errors() {
        let meta = meta_with(vec!["hub"], vec![create("hub"), deploy("typo")]);
        let diags = run(&meta);
        assert!(diags.iter().any(|d| d.severity == Severity::Error
            && d.message.contains("deploy-manifests")
            && d.message.contains("'typo'")));
    }

    #[test]
    fn duplicate_create_cluster_errors() {
        let meta = meta_with(vec!["hub"], vec![create("hub"), create("hub")]);
        let diags = run(&meta);
        assert!(
            diags.iter().any(|d| d.severity == Severity::Error
                && d.message.contains("more than one create-cluster"))
        );
    }

    #[test]
    fn secret_copy_before_create_errors() {
        let meta = meta_with(
            vec!["hub", "spoke"],
            vec![create("hub"), copy("s", "spoke", "hub"), create("spoke")],
        );
        let diags = run(&meta);
        assert!(
            diags
                .iter()
                .any(|d| d.severity == Severity::Error
                    && d.message.contains("before cluster 'spoke'"))
        );
    }

    #[test]
    fn an_argocd_bootstrap_naming_an_unknown_cluster_is_caught() {
        let step = planned_step(
            "bootstrap-argocd-typo",
            "bootstrap-argocd-kubectl-ssa",
            serde_json::json!({ "target": "typo", "manifestRoot": "bootstrap/typo" }),
        );
        let meta = meta_with(vec!["hub"], vec![create("hub"), step]);
        assert!(
            run(&meta)
                .iter()
                .any(|d| d.severity == Severity::Error && d.message.contains("typo")),
            "a target on an argocd bootstrap step must be linted like any other"
        );
    }

    #[test]
    fn secret_copy_between_external_clusters_is_silent() {
        let meta = meta_with(vec!["hub", "spoke"], vec![copy("s", "hub", "spoke")]);
        assert!(run(&meta).is_empty());
    }
}

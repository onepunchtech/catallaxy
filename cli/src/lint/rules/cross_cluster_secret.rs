use std::path::PathBuf;

use crate::domain::diagnostic::{Diagnostic, Severity};
use crate::domain::plan::{CrossClusterSecretCopyParams, StepParams};

use super::{LabCheckContext, LabCheckRule};

pub struct CrossClusterSecret;

impl LabCheckRule for CrossClusterSecret {
    fn name(&self) -> &'static str {
        "cross-cluster-secret"
    }
    fn check(&self, ctx: &LabCheckContext<'_>) -> Vec<Diagnostic> {
        let mut diags = Vec::new();
        for step in ctx.deployment_plan {
            let StepParams::CrossClusterSecretCopy(p) = &step.params else {
                continue;
            };
            let CrossClusterSecretCopyParams {
                name,
                source_cluster,
                source_namespace,
                source_secret,
                target_cluster,
                ..
            } = p;

            let cluster_names: &[String] = &ctx.metadata.cluster_names;
            let has_source = cluster_names.iter().any(|c| c == source_cluster);
            let has_target = cluster_names.iter().any(|c| c == target_cluster);

            if !has_source {
                diags.push(diag(
                    Severity::Error,
                    name,
                    format!(
                        "cross-cluster secret '{}' references unknown source cluster '{}'",
                        name, source_cluster,
                    ),
                ));
            }
            if !has_target {
                diags.push(diag(
                    Severity::Error,
                    name,
                    format!(
                        "cross-cluster secret '{}' references unknown target cluster '{}'",
                        name, target_cluster,
                    ),
                ));
            }

            if has_source {
                let source_present = ctx
                    .resources_by_cluster
                    .get(source_cluster)
                    .map(|resources| {
                        resources.iter().any(|r| {
                            r.is_secret()
                                && r.name == *source_secret
                                && r.namespace.as_deref() == Some(source_namespace.as_str())
                        })
                    })
                    .unwrap_or(false);

                if !source_present {
                    diags.push(diag(
                        Severity::Warning,
                        name,
                        format!(
                            "cross-cluster secret '{}' source Secret '{}/{}' not found in \
                             cluster '{}' manifests \u{2014} runtime-generated? if so, ignore",
                            name, source_namespace, source_secret, source_cluster,
                        ),
                    ));
                }
            }
        }
        diags
    }
}

fn diag(severity: Severity, resource: &str, message: String) -> Diagnostic {
    Diagnostic {
        severity,
        check: "cross-cluster-secret",
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
    use crate::domain::plan::PlannedStep;
    use crate::lint::rules::test_util::make_resource;
    use crate::lint::{ImagePolicy, LabMetadata};

    fn ctx_with(
        clusters: Vec<&str>,
        resources: HashMap<String, Vec<crate::lint::manifest::K8sResource>>,
        plan: Vec<PlannedStep>,
    ) -> (
        LabMetadata,
        HashMap<String, Vec<crate::lint::manifest::K8sResource>>,
        Vec<PlannedStep>,
    ) {
        let meta = LabMetadata {
            name: "test".into(),
            prefix: "".into(),
            cluster_names: clusters.into_iter().map(String::from).collect(),
            lab_namespaces: HashMap::new(),
            clusters: HashMap::new(),
            images: ImagePolicy::default(),
            lint: Default::default(),
            assertions: vec![],
            warnings: vec![],
            deployment_plan: plan.clone(),
        };
        (meta, resources, plan)
    }

    fn run(
        meta: &LabMetadata,
        res: &HashMap<String, Vec<crate::lint::manifest::K8sResource>>,
    ) -> Vec<Diagnostic> {
        let ctx = LabCheckContext {
            metadata: meta,
            resources_by_cluster: res,
            deployment_plan: &meta.deployment_plan,
        };
        CrossClusterSecret.check(&ctx)
    }

    fn copy_step(
        name: &str,
        src_c: &str,
        src_ns: &str,
        src_secret: &str,
        tgt_c: &str,
    ) -> PlannedStep {
        crate::lint::rules::test_util::planned_step(
            name,
            "cross-cluster-secret-copy",
            serde_json::json!({
                "name": name,
                "sourceCluster": src_c,
                "sourceNamespace": src_ns,
                "sourceSecret": src_secret,
                "targetCluster": tgt_c,
                "targetNamespace": "dst-ns",
                "targetSecret": name,
            }),
        )
    }

    #[test]
    fn unknown_source_cluster_is_error() {
        let (meta, res, _) = ctx_with(
            vec!["hub"],
            HashMap::new(),
            vec![copy_step("x", "typo-src", "ns", "sec", "hub")],
        );
        let diags = run(&meta, &res);
        assert!(diags.iter().any(|d| d.severity == Severity::Error
            && d.message.contains("unknown source cluster 'typo-src'")));
    }

    #[test]
    fn unknown_target_cluster_is_error() {
        let (meta, res, _) = ctx_with(
            vec!["hub"],
            HashMap::new(),
            vec![copy_step("x", "hub", "ns", "sec", "typo-tgt")],
        );
        let diags = run(&meta, &res);
        assert!(diags.iter().any(|d| d.severity == Severity::Error
            && d.message.contains("unknown target cluster 'typo-tgt'")));
    }

    #[test]
    fn present_source_secret_is_silent() {
        let secret = make_resource(
            "apiVersion: v1\nkind: Secret\nmetadata:\n  name: sec\n  namespace: ns\n",
        );
        let mut res = HashMap::new();
        res.insert("hub".to_string(), vec![secret]);
        let (meta, res, _) = ctx_with(
            vec!["hub", "spoke"],
            res,
            vec![copy_step("x", "hub", "ns", "sec", "spoke")],
        );
        assert!(run(&meta, &res).is_empty());
    }

    #[test]
    fn missing_source_secret_is_warning() {
        let (meta, res, _) = ctx_with(
            vec!["hub", "spoke"],
            HashMap::new(),
            vec![copy_step("x", "hub", "ns", "sec", "spoke")],
        );
        let diags = run(&meta, &res);
        assert_eq!(diags.len(), 1);
        assert_eq!(diags[0].severity, Severity::Warning);
        assert!(diags[0].message.contains("runtime-generated"));
    }
}

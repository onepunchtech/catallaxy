use std::path::PathBuf;

use crate::domain::diagnostic::{Diagnostic, Severity};

use super::{CheckContext, CheckRule};
use crate::lint::{ClusterMetadata, LabMetadata};

pub struct Assertions;

impl CheckRule for Assertions {
    fn name(&self) -> &'static str {
        "assertions"
    }
    fn check(&self, ctx: &CheckContext<'_>) -> Vec<Diagnostic> {
        match ctx.cluster_meta {
            Some(cm) => check_cluster(ctx.cluster, cm),
            None => Vec::new(),
        }
    }
}

pub fn check_cluster(cluster: &str, meta: &ClusterMetadata) -> Vec<Diagnostic> {
    let mut diags = Vec::new();
    for a in &meta.assertions {
        if !a.assertion {
            diags.push(Diagnostic {
                severity: Severity::Error,
                check: "assertions",
                cluster: cluster.to_string(),
                file: PathBuf::new(),
                resource: "cluster.assertions".to_string(),
                message: a.message.clone(),
            });
        }
    }
    for w in &meta.warnings {
        diags.push(Diagnostic {
            severity: Severity::Warning,
            check: "assertions",
            cluster: cluster.to_string(),
            file: PathBuf::new(),
            resource: "cluster.warnings".to_string(),
            message: w.clone(),
        });
    }
    diags
}

pub fn check_lab(meta: &LabMetadata) -> Vec<Diagnostic> {
    let mut diags = Vec::new();
    for a in &meta.assertions {
        if !a.assertion {
            diags.push(Diagnostic {
                severity: Severity::Error,
                check: "assertions",
                cluster: "<lab>".to_string(),
                file: PathBuf::new(),
                resource: "lab.assertions".to_string(),
                message: a.message.clone(),
            });
        }
    }
    for w in &meta.warnings {
        diags.push(Diagnostic {
            severity: Severity::Warning,
            check: "assertions",
            cluster: "<lab>".to_string(),
            file: PathBuf::new(),
            resource: "lab.warnings".to_string(),
            message: w.clone(),
        });
    }
    diags
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lint::AssertionMetadata;

    #[test]
    fn failed_cluster_assertion_becomes_error() {
        let meta = ClusterMetadata {
            network_policies: Default::default(),
            projections: Default::default(),
            lint: Default::default(),
            assertions: vec![AssertionMetadata {
                assertion: false,
                message: "nope".into(),
            }],
            runtime_materialised: Vec::new(),
            warnings: vec![],
        };
        let diags = check_cluster("c", &meta);
        assert_eq!(diags.len(), 1);
        assert_eq!(diags[0].severity, Severity::Error);
        assert_eq!(diags[0].message, "nope");
    }

    #[test]
    fn cluster_warning_becomes_warning_diagnostic() {
        let meta = ClusterMetadata {
            network_policies: Default::default(),
            projections: Default::default(),
            lint: Default::default(),
            assertions: vec![],
            runtime_materialised: Vec::new(),
            warnings: vec!["heads up".into()],
        };
        let diags = check_cluster("c", &meta);
        assert_eq!(diags.len(), 1);
        assert_eq!(diags[0].severity, Severity::Warning);
    }

    #[test]
    fn passing_cluster_assertion_is_silent() {
        let meta = ClusterMetadata {
            network_policies: Default::default(),
            projections: Default::default(),
            lint: Default::default(),
            assertions: vec![AssertionMetadata {
                assertion: true,
                message: "unused".into(),
            }],
            runtime_materialised: Vec::new(),
            warnings: vec![],
        };
        assert!(check_cluster("c", &meta).is_empty());
    }
}

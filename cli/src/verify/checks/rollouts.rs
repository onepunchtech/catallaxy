use crate::io;
use crate::verify::{Diagnostic, Severity, VerifyContext, diag};

const CHECK: &str = "rollouts";

pub fn run(ctx: &VerifyContext<'_>) -> Vec<Diagnostic> {
    let mut diags = Vec::new();
    for cluster in &ctx.lab.cluster_names {
        let Some(context) = ctx.context_for(cluster) else {
            diags.push(diag(
                Severity::Error,
                CHECK,
                cluster,
                "kubeconfig",
                "the lab resolves no kube context for this cluster, so no rollout could be checked"
                    .to_string(),
            ));
            continue;
        };
        if !io::kubectl::api_reachable(context) {
            continue;
        }

        let mut present = Vec::new();
        for namespace in ctx.namespaces_for(cluster) {
            if io::kubectl::namespace_exists(context, namespace) {
                present.push(namespace.clone());
            } else {
                diags.push(diag(
                    Severity::Error,
                    CHECK,
                    cluster,
                    namespace,
                    "the lab declares this namespace but the cluster does not have it".to_string(),
                ));
            }
        }

        let workloads = match io::kubectl::get_workload_readiness(context, &present) {
            Ok(w) => w,
            Err(e) => {
                diags.push(diag(
                    Severity::Error,
                    CHECK,
                    cluster,
                    "workloads",
                    format!("could not read workload state: {e}"),
                ));
                continue;
            }
        };

        for w in workloads {
            if w.ready < w.desired {
                diags.push(diag(
                    Severity::Error,
                    CHECK,
                    cluster,
                    &format!("{}/{}/{}", w.namespace, w.kind, w.name),
                    format!("{}/{} replicas ready", w.ready, w.desired),
                ));
            }
        }
    }
    diags
}

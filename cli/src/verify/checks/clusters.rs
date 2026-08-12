use crate::io;
use crate::verify::{Diagnostic, Severity, VerifyContext, diag};

const CHECK: &str = "clusters";

pub fn run(ctx: &VerifyContext<'_>) -> Vec<Diagnostic> {
    let mut diags = Vec::new();
    for cluster in &ctx.lab.cluster_names {
        let Some(context) = ctx.context_for(cluster) else {
            diags.push(diag(
                Severity::Error,
                CHECK,
                cluster,
                "kubeconfig",
                "the lab resolves no kube context for this cluster, so nothing can address it"
                    .to_string(),
            ));
            continue;
        };

        if !io::kubectl::api_reachable(context) {
            diags.push(diag(
                Severity::Error,
                CHECK,
                cluster,
                context,
                format!("apiserver at context '{context}' does not answer"),
            ));
        }
    }
    diags
}

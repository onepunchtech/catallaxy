use super::crossplane::is_crossplane_managed;
use super::diagnostics::namespace_phase;
use console::style;

use crate::io::process::run_capture;

pub fn strip_finalizers_in_terminating_namespaces(
    kube_ctx: &str,
    namespaces: &[String],
) -> Vec<String> {
    let mut stripped = Vec::new();

    let terminating: Vec<String> = namespaces
        .iter()
        .filter(|ns| namespace_phase(kube_ctx, ns).as_deref() == Some("Terminating"))
        .cloned()
        .collect();

    for ns in namespaces {
        if !terminating.contains(ns) {
            println!(
                "{}   {ns} is not Terminating, leaving its finalizers alone",
                style(">>>").dim(),
            );
        }
    }
    if terminating.is_empty() {
        return stripped;
    }

    let mut list = super::run::command();
    list.args([
        "--context",
        kube_ctx,
        "get",
        "crd",
        "-o",
        r#"jsonpath={range .items[?(@.spec.scope=="Namespaced")]}{.spec.names.plural}.{.spec.group}{"\n"}{end}"#,
    ]);
    let crd_names: Vec<String> = run_capture(&mut list)
        .unwrap_or_default()
        .lines()
        .filter(|l| !l.is_empty())
        .map(String::from)
        .collect();

    for kind in &crd_names {
        if is_crossplane_managed(kind) {
            println!(
                "{}   skipping {kind}: stripping a Crossplane finalizer orphans the cloud resource",
                style(">>>").yellow(),
            );
            continue;
        }
        for ns in &terminating {
            let mut get = super::run::command();
            get.args([
                "--context",
                kube_ctx,
                "-n",
                ns,
                "get",
                kind,
                "-o",
                "jsonpath={.items[*].metadata.name}",
            ]);
            let names: Vec<String> = run_capture(&mut get)
                .unwrap_or_default()
                .split_whitespace()
                .map(String::from)
                .collect();
            if names.is_empty() {
                continue;
            }
            for name in &names {
                let mut patch = super::run::command();
                patch.args([
                    "--context",
                    kube_ctx,
                    "-n",
                    ns,
                    "patch",
                    &format!("{kind}/{name}"),
                    "--type=merge",
                    "-p",
                    r#"{"metadata":{"finalizers":[]}}"#,
                ]);
                if run_capture(&mut patch).is_ok() {
                    println!(
                        "{}   stripped finalizers: {}/{}/{}",
                        style(">>>").dim(),
                        ns,
                        kind,
                        name
                    );
                    stripped.push(format!("{ns}/{kind}/{name}"));
                }
            }
        }
    }
    stripped
}

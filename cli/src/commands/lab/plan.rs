use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, bail};
use console::style;
use serde_json::Value;

use crate::config::Context as CataContext;
use crate::domain::{PlannedStep, StepParams};

pub async fn run(
    ctx: &CataContext,
    name: Option<&str>,
    teardown: bool,
    stable: bool,
    from_file: Option<PathBuf>,
    diff: Option<PathBuf>,
) -> Result<()> {
    let stable = stable || diff.is_some();

    let steps = load_steps(ctx, name, teardown, from_file.as_deref())?;
    let parsed = parse_steps(&steps, teardown)?;

    if stable {
        let text = format_stable(&steps);
        if let Some(baseline) = diff {
            if !run_diff(&text, &baseline)? {
                std::process::exit(1);
            }
            return Ok(());
        }
        print!("{text}");
        return Ok(());
    }

    render_pretty(name.unwrap_or(""), teardown, &parsed);
    Ok(())
}

fn load_steps(
    ctx: &CataContext,
    name: Option<&str>,
    teardown: bool,
    from_file: Option<&Path>,
) -> Result<Vec<Value>> {
    let plan_key = if teardown {
        "teardownPlan"
    } else {
        "deploymentPlan"
    };

    if let Some(path) = from_file {
        let raw = fs::read_to_string(path)
            .with_context(|| format!("reading plan file {}", path.display()))?;
        let v: Value = serde_json::from_str(&raw)
            .with_context(|| format!("parsing plan JSON from {}", path.display()))?;
        return extract_plan_array(&v, plan_key).with_context(|| {
            format!(
                "extracting {plan_key} from {} (expected a bare array or one nested under {plan_key}, out.{plan_key}, or lab.out.{plan_key})",
                path.display()
            )
        });
    }

    let lab_name =
        name.ok_or_else(|| anyhow::anyhow!("lab name is required unless --from-file is set"))?;
    let lab = crate::io::nix::get_lab_config(ctx, lab_name)?;
    Ok(lab
        .get(plan_key)
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default())
}

fn extract_plan_array(v: &Value, plan_key: &str) -> Result<Vec<Value>> {
    if let Some(arr) = v.as_array() {
        return Ok(arr.clone());
    }
    for path in [
        vec![plan_key],
        vec!["out", plan_key],
        vec!["lab", "out", plan_key],
    ] {
        let mut cur = v;
        let mut ok = true;
        for segment in &path {
            match cur.get(*segment) {
                Some(next) => cur = next,
                None => {
                    ok = false;
                    break;
                }
            }
        }
        if ok {
            if let Some(arr) = cur.as_array() {
                return Ok(arr.clone());
            }
        }
    }
    bail!("no plan array found");
}

fn parse_steps(steps: &[Value], teardown: bool) -> Result<Vec<PlannedStep>> {
    let label = if teardown { "teardown" } else { "deployment" };
    steps
        .iter()
        .enumerate()
        .map(|(i, v)| {
            serde_json::from_value(v.clone())
                .with_context(|| format!("parsing {label} plan step {}", i + 1))
        })
        .collect()
}

fn format_stable(steps: &[Value]) -> String {
    let mut out = String::new();
    for (i, step) in steps.iter().enumerate() {
        let obj = match step.as_object() {
            Some(o) => o,
            None => {
                out.push_str(&format!(
                    "[{:03}] <non-object step: {}>\n",
                    i + 1,
                    serde_json::to_string(step).unwrap_or_default()
                ));
                continue;
            }
        };

        out.push_str(&format!(
            "[{:03}] {} name={}",
            i + 1,
            obj.get("kind")
                .and_then(|v| v.as_str())
                .unwrap_or("<unknown>"),
            obj.get("name")
                .and_then(|v| v.as_str())
                .unwrap_or("<unnamed>"),
        ));
        if let Some(cluster) = obj.get("cluster").and_then(|v| v.as_str()) {
            out.push_str(&format!(" cluster={cluster}"));
        }
        push_policy(&mut out, obj.get("policy"));
        push_params(&mut out, obj.get("params"));
        out.push('\n');
    }
    normalize_store_paths(&out)
}

fn push_policy(out: &mut String, value: Option<&Value>) {
    let Some(obj) = value.and_then(|v| v.as_object()) else {
        return;
    };
    if obj.get("onFailure").and_then(|v| v.as_str()) == Some("continue") {
        out.push_str(" policy.onFailure=continue");
    }
    if obj.get("interactive").and_then(|v| v.as_bool()) == Some(true) {
        out.push_str(" policy.interactive=true");
    }
    if let Some(cluster) = obj.get("skipIfClusterReachable").and_then(|v| v.as_str()) {
        out.push_str(&format!(" policy.skipIfClusterReachable={cluster}"));
    }
}

fn push_params(out: &mut String, value: Option<&Value>) {
    let Some(obj) = value.and_then(|v| v.as_object()) else {
        return;
    };
    let mut keys: Vec<&String> = obj.keys().filter(|k| !is_at_default(&obj[*k])).collect();
    keys.sort();
    for key in keys {
        out.push_str(" params.");
        out.push_str(key);
        out.push('=');
        out.push_str(&render_value(&obj[key]));
    }
}

fn is_at_default(v: &Value) -> bool {
    match v {
        Value::Null => true,
        Value::Bool(b) => !b,
        Value::Array(a) => a.is_empty(),
        Value::Object(m) => m.is_empty(),
        _ => false,
    }
}

fn render_value(v: &Value) -> String {
    match v {
        Value::Null => "null".to_string(),
        Value::Bool(b) => b.to_string(),
        Value::Number(n) => n.to_string(),
        Value::String(s) => {
            let needs_quote = s
                .chars()
                .any(|c| c.is_whitespace() || c == '=' || c == '"' || c == '\\');
            if needs_quote {
                serde_json::to_string(s).unwrap_or_else(|_| format!("{s:?}"))
            } else {
                s.clone()
            }
        }
        Value::Array(_) | Value::Object(_) => serde_json::to_string(&canonicalize(v))
            .unwrap_or_else(|_| "<unserializable>".to_string()),
    }
}

fn canonicalize(v: &Value) -> Value {
    match v {
        Value::Object(m) => {
            let mut keys: Vec<&String> = m.keys().collect();
            keys.sort();
            let mut sorted = serde_json::Map::with_capacity(m.len());
            for k in keys {
                sorted.insert(k.clone(), canonicalize(&m[k]));
            }
            Value::Object(sorted)
        }
        Value::Array(a) => Value::Array(a.iter().map(canonicalize).collect()),
        _ => v.clone(),
    }
}

fn normalize_store_paths(s: &str) -> String {
    const PREFIX: &str = "/nix/store/";
    let mut result = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(idx) = rest.find(PREFIX) {
        result.push_str(&rest[..idx]);
        result.push_str(PREFIX);
        let after = &rest[idx + PREFIX.len()..];
        let bytes = after.as_bytes();
        if bytes.len() >= 33
            && bytes[32] == b'-'
            && bytes[..32]
                .iter()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
        {
            result.push_str("HASH");
            rest = &after[32..];
        } else {
            rest = after;
        }
    }
    result.push_str(rest);
    result
}

fn run_diff(actual: &str, baseline_path: &Path) -> Result<bool> {
    let baseline = fs::read_to_string(baseline_path)
        .with_context(|| format!("reading baseline {}", baseline_path.display()))?;
    if actual == baseline {
        eprintln!(
            "plan matches baseline {}",
            style(baseline_path.display()).dim()
        );
        return Ok(true);
    }

    let mut tmp = tempfile::NamedTempFile::new().context("creating temp file for diff")?;
    tmp.write_all(actual.as_bytes())
        .context("writing actual plan to temp file")?;
    tmp.flush().ok();

    let baseline_str = baseline_path.to_string_lossy();
    let tmp_str = tmp.path().to_string_lossy();
    let status = Command::new("diff")
        .args(["-u", &baseline_str, &tmp_str])
        .status();
    match status {
        Ok(_) => {}
        Err(e) => {
            eprintln!(
                "{}: `diff -u` failed ({e}); plan text differs from baseline",
                style("error").red()
            );
        }
    }
    Ok(false)
}

fn render_pretty(lab_name: &str, teardown: bool, steps: &[PlannedStep]) {
    let plan_label = if teardown { "Teardown" } else { "Deployment" };

    println!(
        "{} {} plan for '{lab_name}'",
        style("catallaxy").cyan().bold(),
        plan_label,
    );
    println!();

    if steps.is_empty() {
        println!("  (no {} plan computed)", plan_label.to_lowercase());
        return;
    }

    for (i, step) in steps.iter().enumerate() {
        println!(
            "  {} {} {}",
            style(format!("{}.", i + 1)).dim(),
            icon(step.type_tag()),
            step.label(),
        );
        if let Some(detail) = detail(&step.params) {
            println!("     {} {}", style("→").dim(), detail);
        }
    }

    println!();
    println!("  {} steps total", style(steps.len().to_string()).bold());
}

fn icon(kind: &str) -> &'static str {
    match kind {
        "setup-services" | "remove-services" => "🔧",
        "warm-cache" => "♨️",
        "create-cluster" => "📦",
        "deploy-manifests" => "🚀",
        "ensure-secrets" => "🔑",
        "wait-for-resources" | "wait-for-cluster-gone" => "⏳",
        "sync-kubeconfig" => "🔗",
        "cross-cluster-secret-copy" => "🔁",
        "publish-images" | "publish-manifests" => "📤",
        "pivot" => "🔄",
        "destroy-cluster" | "delete-managed-resource" => "💥",
        "run-script" => "⚡",
        "remove-network" | "docker-network-create" => "🌐",
        _ => "•",
    }
}

fn detail(params: &StepParams) -> Option<String> {
    match params {
        StepParams::CreateCluster { name, provisioner } => {
            Some(format!("cluster={name}, provisioner={provisioner}"))
        }
        StepParams::DeployManifests {
            target, bootstrap, ..
        } => Some(if *bootstrap {
            format!("target={target} (bootstrap stage)")
        } else {
            format!("target={target}")
        }),
        StepParams::CrossClusterSecretCopy {
            source_cluster,
            source_namespace,
            source_secret,
            target_cluster,
            target_namespace,
            target_secret,
            ..
        } => Some(format!(
            "{source_cluster}:{source_namespace}/{source_secret} → \
             {target_cluster}:{target_namespace}/{target_secret}"
        )),
        StepParams::WaitForResources {
            target, resources, ..
        } => Some(format!(
            "on={target}, waiting for: {}",
            resources
                .iter()
                .map(resource_label)
                .collect::<Vec<_>>()
                .join(", ")
        )),
        StepParams::SyncKubeconfig {
            target, clusters, ..
        } => Some(format!("via={target}, clusters: {}", clusters.join(", "))),
        StepParams::Pivot {
            bootstrap_context,
            target_context,
            ..
        } => Some(format!("{bootstrap_context} → {target_context}")),
        StepParams::RunScript { bin, .. } => Some(format!("bin={bin}")),
        StepParams::DestroyCluster { name, .. } => Some(format!("cluster={name}")),
        _ => None,
    }
}

fn resource_label(r: &Value) -> String {
    let kind = r["kind"].as_str();
    let name = r["name"].as_str();
    let selector = r["labelSelector"].as_str();
    match (kind, name, selector) {
        (Some(k), Some(n), _) => format!("{k}/{n}"),
        (Some(k), _, Some(s)) => format!("{k}[{s}]"),
        (None, Some(n), _) => n.to_string(),
        _ => "?".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn step(kind: &str, params: serde_json::Value) -> Value {
        json!({
            "name": format!("a-{kind}"),
            "kind": kind,
            "description": "a description the stable format drops",
            "policy": { "retry": "idempotent" },
            "params": params,
        })
    }

    #[test]
    fn stable_names_the_step_and_sorts_its_params() {
        let steps = vec![step(
            "create-cluster",
            json!({ "provisioner": "k3d", "name": "mgmt" }),
        )];
        let out = format_stable(&steps);
        assert_eq!(
            out,
            "[001] create-cluster name=a-create-cluster params.name=mgmt params.provisioner=k3d\n"
        );
    }

    #[test]
    fn stable_skips_nulls_empty_containers_and_false_flags() {
        let steps = vec![step(
            "deploy-manifests",
            json!({ "target": "core", "kubeContext": null, "bootstrap": false }),
        )];
        let out = format_stable(&steps);
        assert_eq!(
            out,
            "[001] deploy-manifests name=a-deploy-manifests params.target=core\n"
        );
    }

    #[test]
    fn stable_shows_policy_only_where_it_departs_from_the_default() {
        let quiet = vec![step("publish-manifests", json!({}))];
        assert_eq!(
            format_stable(&quiet),
            "[001] publish-manifests name=a-publish-manifests\n"
        );

        let loud = vec![json!({
            "name": "cleanup",
            "kind": "run-script",
            "cluster": "mgmt",
            "policy": {
                "retry": "idempotent",
                "onFailure": "continue",
                "interactive": true,
                "skipIfClusterReachable": "mgmt",
            },
            "params": { "bin": "/bin/x" },
        })];
        assert_eq!(
            format_stable(&loud),
            "[001] run-script name=cleanup cluster=mgmt policy.onFailure=continue \
             policy.interactive=true policy.skipIfClusterReachable=mgmt params.bin=/bin/x\n"
        );
    }

    #[test]
    fn stable_renders_arrays_as_canonical_json() {
        let steps = vec![step(
            "wait-for-resources",
            json!({
                "target": "core",
                "resources": [
                    { "name": "b", "kind": "K" },
                    { "name": "a", "kind": "K" },
                ],
            }),
        )];
        let out = format_stable(&steps);
        assert!(
            out.contains(r#"params.resources=[{"kind":"K","name":"b"},{"kind":"K","name":"a"}]"#),
            "got: {out}"
        );
    }

    #[test]
    fn stable_quotes_strings_with_whitespace() {
        let steps = vec![step(
            "bootstrap-forgejo-repos",
            json!({ "target": "mgmt", "jobLabelSelector": "app = forgejo" }),
        )];
        let out = format_stable(&steps);
        assert!(
            out.contains(r#"params.jobLabelSelector="app = forgejo""#),
            "got: {out}"
        );
    }

    #[test]
    fn a_step_the_cli_cannot_dispatch_is_refused_rather_than_rendered() {
        let steps = vec![step("deploy-manifests", json!({}))];
        assert!(
            parse_steps(&steps, false).is_err(),
            "deploy-manifests without a target must not reach the executor"
        );
    }

    #[test]
    fn normalize_store_paths_collapses_hash() {
        let input = "/nix/store/abcdef0123456789abcdef0123456789-foo/bin/foo";
        let out = normalize_store_paths(input);
        assert_eq!(out, "/nix/store/HASH-foo/bin/foo");
    }

    #[test]
    fn normalize_store_paths_leaves_non_matching_alone() {
        let input = "/nix/store/short-foo /nix/store/UPPERCASE00000000000000000000000-x";
        let out = normalize_store_paths(input);
        assert_eq!(out, input);
    }

    #[test]
    fn normalize_store_paths_multiple_occurrences() {
        let input = "a /nix/store/00000000000000000000000000000000-x b /nix/store/11111111111111111111111111111111-y c";
        let out = normalize_store_paths(input);
        assert_eq!(out, "a /nix/store/HASH-x b /nix/store/HASH-y c");
    }

    #[test]
    fn extract_plan_accepts_bare_array() {
        let v = json!([{ "kind": "setup-services" }]);
        let steps = extract_plan_array(&v, "deploymentPlan").unwrap();
        assert_eq!(steps.len(), 1);
    }

    #[test]
    fn extract_plan_walks_lab_out_nesting() {
        let v = json!({
            "lab": { "out": { "deploymentPlan": [{ "kind": "setup-services" }] } }
        });
        let steps = extract_plan_array(&v, "deploymentPlan").unwrap();
        assert_eq!(steps.len(), 1);
    }
}

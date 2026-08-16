use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use console::style;
use serde_json::Value;

use crate::config::Context as CataContext;

pub async fn run(
    ctx: &CataContext,
    name: Option<&str>,
    cluster: Option<&str>,
    stable: bool,
    from_file: Option<PathBuf>,
    diff: Option<PathBuf>,
) -> Result<()> {
    let stable = stable || diff.is_some();

    let waves = load_waves(ctx, name, cluster, from_file.as_deref())?;

    if stable {
        let text = format_stable(&waves);
        if let Some(baseline) = diff {
            if !run_diff(&text, &baseline)? {
                std::process::exit(1);
            }
            return Ok(());
        }
        print!("{text}");
        return Ok(());
    }

    render_pretty(name.unwrap_or(""), cluster.unwrap_or(""), &waves);
    Ok(())
}

fn load_waves(
    ctx: &CataContext,
    name: Option<&str>,
    cluster: Option<&str>,
    from_file: Option<&Path>,
) -> Result<Vec<Vec<Value>>> {
    if let Some(path) = from_file {
        let raw = crate::io::fs::read_to_string(path)
            .with_context(|| format!("reading manifest-waves file {}", path.display()))?;
        let v: Value = serde_json::from_str(&raw)
            .with_context(|| format!("parsing JSON from {}", path.display()))?;
        return extract_waves(&v, cluster).with_context(|| {
            format!(
                "extracting manifestWaves from {} (expected a `[[bundle]]` array, or an object with a `manifestWaves` key at top level or under `clusters.<name>`)",
                path.display()
            )
        });
    }

    let lab_name =
        name.ok_or_else(|| anyhow::anyhow!("lab name is required unless --from-file is set"))?;
    let lab = crate::io::nix::get_lab_config(ctx, lab_name)?;
    extract_waves(&lab, cluster).with_context(|| {
        format!(
            "extracting manifestWaves for lab '{lab_name}' cluster '{}'",
            cluster.unwrap_or("<any>")
        )
    })
}

fn extract_waves(v: &Value, cluster: Option<&str>) -> Result<Vec<Vec<Value>>> {
    if let Some(outer) = v.as_array() {
        let mut waves = Vec::with_capacity(outer.len());
        for w in outer {
            let inner = w
                .as_array()
                .ok_or_else(|| anyhow::anyhow!("expected `[[bundle]]` structure"))?;
            waves.push(inner.clone());
        }
        return Ok(waves);
    }

    if let Some(w) = v.get("manifestWaves").and_then(|v| v.as_array()) {
        return Ok(w
            .iter()
            .map(|inner| inner.as_array().cloned().unwrap_or_default())
            .collect());
    }

    let clusters = v
        .get("clusters")
        .and_then(|v| v.as_object())
        .ok_or_else(|| anyhow::anyhow!("no `clusters` object in JSON, cannot resolve waves"))?;

    if let Some(target) = cluster {
        let cluster_val = clusters.get(target).ok_or_else(|| {
            anyhow::anyhow!(
                "cluster '{}' not found. Available: {}",
                target,
                clusters.keys().cloned().collect::<Vec<_>>().join(", ")
            )
        })?;
        let waves = cluster_val
            .get("manifestWaves")
            .and_then(|v| v.as_array())
            .ok_or_else(|| anyhow::anyhow!("cluster '{}' has no manifestWaves", target))?;
        return Ok(waves
            .iter()
            .map(|inner| inner.as_array().cloned().unwrap_or_default())
            .collect());
    }

    if clusters.len() > 1 {
        bail!(
            "lab has {} clusters ({}); pass --cluster=<name>",
            clusters.len(),
            clusters.keys().cloned().collect::<Vec<_>>().join(", ")
        );
    }

    let (only_name, only_val) = clusters
        .iter()
        .next()
        .ok_or_else(|| anyhow::anyhow!("lab has no clusters"))?;
    let waves = only_val
        .get("manifestWaves")
        .and_then(|v| v.as_array())
        .ok_or_else(|| anyhow::anyhow!("cluster '{}' has no manifestWaves", only_name))?;
    Ok(waves
        .iter()
        .map(|inner| inner.as_array().cloned().unwrap_or_default())
        .collect())
}

fn format_stable(waves: &[Vec<Value>]) -> String {
    let mut out = String::new();
    for (wave_idx, wave) in waves.iter().enumerate() {
        out.push_str(&format!(
            "=== wave {:03} ({} bundle{}) ===\n",
            wave_idx + 1,
            wave.len(),
            if wave.len() == 1 { "" } else { "s" }
        ));
        for (bundle_idx, bundle) in wave.iter().enumerate() {
            let obj = match bundle.as_object() {
                Some(o) => o,
                None => {
                    out.push_str(&format!(
                        "[{:03}] <non-object bundle: {}>\n",
                        bundle_idx + 1,
                        serde_json::to_string(bundle).unwrap_or_default()
                    ));
                    continue;
                }
            };

            let mut keys: Vec<&String> = obj
                .keys()
                .filter(|k| {
                    if k.as_str() == "readyProbe" {
                        return false;
                    }
                    match &obj[*k] {
                        Value::Null => false,
                        Value::Array(a) if a.is_empty() => false,
                        Value::Object(m) if m.is_empty() => false,
                        _ => true,
                    }
                })
                .collect();
            keys.sort();

            out.push_str(&format!("[{:03}]", bundle_idx + 1));
            for key in keys {
                out.push(' ');
                out.push_str(key);
                out.push('=');
                out.push_str(&render_value(&obj[key]));
            }
            out.push('\n');
        }
    }
    normalize_store_paths(&out)
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
    let baseline = crate::io::fs::read_to_string(baseline_path)
        .with_context(|| format!("reading baseline {}", baseline_path.display()))?;
    if actual == baseline {
        eprintln!(
            "manifest waves match baseline {}",
            style(baseline_path.display()).dim()
        );
        return Ok(true);
    }
    let mut tmp = tempfile::NamedTempFile::new().context("creating temp file for diff")?;
    tmp.write_all(actual.as_bytes())
        .context("writing actual waves to temp file")?;
    tmp.flush().ok();

    let status = crate::io::diff::unified(baseline_path, tmp.path());
    if let Err(e) = status {
        eprintln!(
            "{}: `diff -u` failed ({e}); waves differ from baseline",
            style("error").red()
        );
    }
    Ok(false)
}

fn render_pretty(lab_name: &str, cluster: &str, waves: &[Vec<Value>]) {
    let total: usize = waves.iter().map(Vec::len).sum();
    println!(
        "{} manifest waves for '{lab_name}' cluster '{cluster}'",
        style("catallaxy").cyan().bold(),
    );
    println!(
        "  {} waves, {} bundles total",
        style(waves.len().to_string()).bold(),
        style(total.to_string()).bold(),
    );
    println!();

    if waves.is_empty() {
        println!("  (no bundles)");
        return;
    }

    for (wave_idx, wave) in waves.iter().enumerate() {
        println!(
            "  {} wave {}/{} ({} bundle{})",
            style("═══").cyan(),
            wave_idx + 1,
            waves.len(),
            wave.len(),
            if wave.len() == 1 { "" } else { "s" },
        );
        for bundle in wave {
            let name = bundle
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or("<unnamed>");
            let has_probe = bundle
                .get("hasReadyProbe")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
            let resource_count = bundle
                .get("resourceCount")
                .and_then(|v| v.as_u64())
                .unwrap_or(0);
            println!(
                "    {} {} {} ({} resources)",
                style("•").dim(),
                if has_probe { "🩺" } else { "  " },
                name,
                resource_count,
            );
        }
    }
}

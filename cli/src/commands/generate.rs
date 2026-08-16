use std::collections::BTreeMap;
use std::io::{self, Read};
use std::path::Path;

use anyhow::{Context, Result};
use clap::Args;
use console::style;
use serde::Deserialize;

use crate::codegen::{
    EmitterConfig, GeneratorOptions, convert_openapi_to_types, emit_crd_types, emit_index,
    emit_k8s_types, parse_crds_from_yaml, parse_openapi_spec,
};
use crate::config::Context as CataContext;

#[derive(Args)]
pub struct GenerateArgs {
    #[arg(
        default_value = "-",
        value_name = "PATH",
        help = "Generator config JSON. '-' reads stdin"
    )]
    config: String,

    #[arg(
        short,
        long,
        value_name = "DIR",
        help = "Where to write the types, overriding the config's outputDir"
    )]
    output: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GenerateConfig {
    output_dir: String,

    #[serde(default)]
    k8s_versions: BTreeMap<String, String>,

    #[serde(default)]
    crds: BTreeMap<String, String>,
}

pub async fn run(_ctx: &CataContext, args: GenerateArgs) -> Result<()> {
    let json = if args.config == "-" {
        let mut buffer = String::new();
        io::stdin()
            .read_to_string(&mut buffer)
            .context("Failed to read from stdin")?;
        buffer
    } else {
        crate::io::fs::read_to_string(&args.config)
            .with_context(|| format!("Failed to read config file: {}", args.config))?
    };

    let mut config: GenerateConfig =
        serde_json::from_str(&json).context("Failed to parse JSON config")?;

    if let Some(output) = args.output {
        config.output_dir = output;
    }

    generate(config)
}

fn generate(config: GenerateConfig) -> Result<()> {
    let output_dir = Path::new(&config.output_dir);

    crate::io::fs::create_dir_all(output_dir.join("k8s"))
        .context("Failed to create k8s directory")?;
    crate::io::fs::create_dir_all(output_dir.join("crds"))
        .context("Failed to create crds directory")?;

    let options = GeneratorOptions::default();
    let emitter_config = EmitterConfig::default();

    let mut k8s_versions = Vec::new();
    let mut crd_names = Vec::new();

    for (version, spec_path) in &config.k8s_versions {
        eprintln!(
            "{} Generating K8s types for {}",
            style(">>>").cyan(),
            version
        );

        let spec_content = crate::io::fs::read_to_string(spec_path)
            .with_context(|| format!("Failed to read spec file: {}", spec_path))?;

        let spec = parse_openapi_spec(&spec_content)
            .with_context(|| format!("Failed to parse OpenAPI spec: {}", spec_path))?;

        eprintln!("    Parsed {} definitions", spec.definitions.len());

        let type_set = convert_openapi_to_types(&spec, version, &options);
        eprintln!("    Found {} resources", type_set.resources.len());

        let nix_code = emit_k8s_types(&type_set, emitter_config.clone());

        let file_name = format!("{}.nix", version.replace('.', "_"));
        let file_path = output_dir.join("k8s").join(&file_name);
        crate::io::fs::write(&file_path, &nix_code)
            .with_context(|| format!("Failed to write {:?}", file_path))?;

        eprintln!("    Wrote {:?}", file_path);
        k8s_versions.push(version.clone());
    }

    for (name, crd_path) in &config.crds {
        eprintln!("{} Generating CRD types for {}", style(">>>").cyan(), name);

        let crd_content = crate::io::fs::read_to_string(crd_path)
            .with_context(|| format!("Failed to read CRD file: {}", crd_path))?;

        let resources = parse_crds_from_yaml(&crd_content, &options)
            .with_context(|| format!("Failed to parse CRD: {}", crd_path))?;

        eprintln!("    Found {} CRD types", resources.len());

        let nix_code = emit_crd_types(name, &resources, emitter_config.clone());

        let file_name = format!("{}.nix", name.replace(['.', '-'], "_"));
        let file_path = output_dir.join("crds").join(&file_name);
        crate::io::fs::write(&file_path, &nix_code)
            .with_context(|| format!("Failed to write {:?}", file_path))?;

        eprintln!("    Wrote {:?}", file_path);
        crd_names.push(name.clone());
    }

    eprintln!("{} Generating index.nix", style(">>>").cyan());
    let index_code = emit_index(&k8s_versions, &crd_names, emitter_config);
    let index_path = output_dir.join("index.nix");
    crate::io::fs::write(&index_path, &index_code).context("Failed to write index.nix")?;
    eprintln!("    Wrote {:?}", index_path);

    eprintln!(
        "\n{} Done! Generated types in {:?}",
        style(">>>").green(),
        output_dir
    );

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_config() {
        let json = r#"{
            "outputDir": "/tmp/generated",
            "k8sVersions": {
                "1.31": "/nix/store/abc/swagger.json"
            },
            "crds": {
                "cert-manager": "/nix/store/xyz/crds.yaml"
            }
        }"#;

        let config: GenerateConfig = serde_json::from_str(json).unwrap();
        assert_eq!(config.output_dir, "/tmp/generated");
        assert_eq!(config.k8s_versions.len(), 1);
        assert_eq!(
            config.k8s_versions.get("1.31").unwrap(),
            "/nix/store/abc/swagger.json"
        );
        assert_eq!(config.crds.len(), 1);
    }
}

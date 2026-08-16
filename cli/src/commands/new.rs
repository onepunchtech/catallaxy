use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use clap::Subcommand;
use console::style;

#[derive(Subcommand)]
pub enum NewCommands {
    #[command(about = "Scaffold a floe: its two files, and the registry line that loads them")]
    Floe {
        #[arg(help = "Floe name, lowercase and hyphenated")]
        name: String,

        #[arg(
            long,
            value_name = "DIR",
            default_value = "floes",
            help = "Directory holding the floe registry"
        )]
        dir: PathBuf,
    },
}

pub async fn run(command: NewCommands) -> Result<()> {
    match command {
        NewCommands::Floe { name, dir } => floe(&name, &dir),
    }
}

pub fn valid_floe_name(name: &str) -> bool {
    !name.is_empty()
        && name.starts_with(|c: char| c.is_ascii_lowercase())
        && name.ends_with(|c: char| c.is_ascii_alphanumeric())
        && name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

fn floe(name: &str, dir: &Path) -> Result<()> {
    if !valid_floe_name(name) {
        bail!(
            "'{name}' is not a floe name. Use lowercase letters, digits and hyphens, \
             starting with a letter: `cata new floe my-thing`. The name becomes a Nix \
             attribute and a Kubernetes label value."
        );
    }

    let floe_dir = dir.join(name);
    if floe_dir.exists() {
        bail!(
            "{} already exists. Nothing was written.",
            floe_dir.display()
        );
    }

    let registry = dir.join("default.nix");
    if !registry.exists() {
        bail!(
            "{} does not exist, so there is no registry to add '{name}' to. Run this from \
             the root of a lab repository, or pass --dir. `nix flake init -t \
             github:onepunchtech/catallaxy#consumer` scaffolds one.",
            registry.display(),
        );
    }

    crate::io::fs::create_dir_all(&floe_dir)
        .with_context(|| format!("creating {}", floe_dir.display()))?;

    write_new(&floe_dir.join("options.nix"), &options_nix(name))?;
    write_new(&floe_dir.join("default.nix"), &default_nix(name))?;

    let registry_source = crate::io::fs::read_to_string(&registry)
        .with_context(|| format!("reading {}", registry.display()))?;
    let updated = register(&registry_source, name).with_context(|| {
        format!(
            "adding '{name}' to {}. Add it by hand: a floe in neither the registry nor a \
             cluster's imports does nothing at all, with no error.",
            registry.display(),
        )
    })?;
    crate::io::fs::write(&registry, updated)
        .with_context(|| format!("writing {}", registry.display()))?;

    println!("{} Created {}", style(">>>").green(), floe_dir.display());
    println!("      options.nix   what a lab may set");
    println!("      default.nix   what it renders");
    println!(
        "{} Registered '{name}' in {}",
        style(">>>").green(),
        registry.display()
    );
    println!();
    println!("Enable it on a cluster:");
    println!("      floes.{name}.enable = true;");
    println!();
    println!("Then check it:");
    println!("      nix flake check");

    Ok(())
}

fn write_new(path: &Path, contents: &str) -> Result<()> {
    if path.exists() {
        bail!("{} already exists", path.display());
    }
    crate::io::fs::write(path, contents).with_context(|| format!("writing {}", path.display()))
}

pub fn register(registry: &str, name: &str) -> Result<String> {
    if registry.contains(&format!("{name} = import ./{name}")) {
        bail!("'{name}' is already in the registry");
    }

    let entry = format!("  {name} = import ./{name} {{ inherit mkFloe lib; }};\n");

    let close = registry
        .rfind('}')
        .context("the registry has no closing brace, so it is not the attrset this expects")?;

    let mut out = String::with_capacity(registry.len() + entry.len());
    out.push_str(&registry[..close]);
    out.push_str(&entry);
    out.push_str(&registry[close..]);
    Ok(out)
}

const PLACEHOLDER: &str = "my-floe";

fn options_nix(name: &str) -> String {
    include_str!("templates/options.nix").replace(PLACEHOLDER, name)
}

fn default_nix(name: &str) -> String {
    include_str!("templates/default.nix").replace(PLACEHOLDER, name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_name_that_becomes_a_label_value_is_accepted() {
        for name in ["hello", "hello-world", "a1", "my-thing-2"] {
            assert!(valid_floe_name(name), "{name}");
        }
    }

    #[test]
    fn a_name_that_would_break_nix_or_kubernetes_is_refused() {
        for name in ["", "Hello", "hello_world", "-hello", "hello-", "1hello"] {
            assert!(!valid_floe_name(name), "{name}");
        }
    }

    #[test]
    fn the_registry_gains_an_entry_inside_the_attrset() {
        let registry = "{ mkFloe, lib }:\n{\n  hello-world = import ./hello-world { inherit mkFloe lib; };\n}\n";

        let out = register(registry, "my-thing").expect("registers");

        assert!(
            out.contains("  my-thing = import ./my-thing { inherit mkFloe lib; };"),
            "{out}"
        );
        assert!(
            out.contains("hello-world = import"),
            "existing entries survive: {out}"
        );
        assert!(out.trim_end().ends_with('}'), "still an attrset: {out}");
    }

    #[test]
    fn an_empty_registry_still_gains_the_entry() {
        let out = register("{ mkFloe, lib }:\n{\n}\n", "solo").expect("registers");
        assert!(out.contains("solo = import ./solo"), "{out}");
    }

    #[test]
    fn registering_twice_is_refused() {
        let registry = "{ mkFloe, lib }:\n{\n  dup = import ./dup { inherit mkFloe lib; };\n}\n";
        assert!(register(registry, "dup").is_err());
    }

    #[test]
    fn every_placeholder_in_the_templates_becomes_the_new_floe_name() {
        for rendered in [options_nix("my-thing"), default_nix("my-thing")] {
            assert!(
                !rendered.contains(PLACEHOLDER),
                "placeholder survived: {rendered}"
            );
            assert!(rendered.contains("my-thing"), "{rendered}");
        }
    }

    #[test]
    fn the_rendered_floe_keeps_the_nix_interpolations_the_template_carries() {
        let rendered = default_nix("my-thing");
        assert!(
            rendered.contains("\"http://my-thing.${cfg.namespace}.svc.cluster.local\""),
            "{rendered}"
        );
        assert!(rendered.contains("name = \"my-thing\";"), "{rendered}");
    }
}

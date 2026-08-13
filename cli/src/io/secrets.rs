use std::path::PathBuf;

use anyhow::{Result, bail};
use console::style;

use crate::config::Context as CataContext;
use std::collections::HashMap;

use crate::domain::SecretsCache;
use crate::domain::secrets::{
    Backend, EnvVarBinding, SecretsSpec, StoreValues, describe_store_problems, validate_store,
};

pub fn load_store(
    ctx: &CataContext,
    lab_name: &str,
    store: &str,
    spec: &SecretsSpec,
) -> Result<StoreValues> {
    match spec.backend_of(store) {
        Backend::Sops => {
            let path = store_file_path(ctx, lab_name, store);
            if !path.exists() {
                bail!(
                    "Secret store '{store}' not found at {}. Run `cata secrets generate` first.",
                    path.display()
                );
            }
            super::sops::decrypt_store(&path)
        }
        Backend::Env => Ok(read_env_store(&spec.env_bindings(store))),
        backend => bail!(
            "store '{store}' has backend {}, which catallaxy does not read",
            backend.as_str()
        ),
    }
}

pub fn read_env_store(bindings: &[EnvVarBinding]) -> StoreValues {
    read_env_store_with(bindings, |var| std::env::var(var).ok())
}

fn read_env_store_with(
    bindings: &[EnvVarBinding],
    get: impl Fn(&str) -> Option<String>,
) -> StoreValues {
    let mut values = StoreValues::new();
    for binding in bindings {
        if let Some(value) = get(&binding.var) {
            values
                .entry(binding.secret.clone())
                .or_default()
                .insert(binding.key.clone(), value);
        }
    }
    values
}

pub fn store_file_path(ctx: &CataContext, lab_name: &str, store_name: &str) -> PathBuf {
    let flake_root = PathBuf::from(ctx.flake_uri());
    let filename = format!("{store_name}.enc.yaml");

    let primary = flake_root.join("secrets").join(lab_name).join(&filename);
    if primary.exists() {
        return primary;
    }

    let fallback = flake_root
        .join("examples/labs/secrets")
        .join(lab_name)
        .join(&filename);
    if fallback.exists() {
        return fallback;
    }

    primary
}

pub fn load_secrets_cache(
    ctx: &CataContext,
    lab_name: &str,
    spec: &SecretsSpec,
    banner: &str,
) -> Result<Option<SecretsCache>> {
    let host_projections = &spec.host_projections;
    let store_names: Vec<String> = spec
        .stores
        .iter()
        .filter(|(_, store)| store.backend.readable_here())
        .map(|(name, _)| name.clone())
        .collect();

    if store_names.is_empty() {
        return Ok(None);
    }

    println!();
    println!("{} {banner}", style(">>>").cyan());

    let mut cache = HashMap::new();
    for store_name in &store_names {
        let values = crate::io::secrets::load_store(ctx, lab_name, store_name, spec)?;
        let problems = validate_store(spec, store_name, &values);
        if !problems.is_empty() {
            bail!(describe_store_problems(
                spec, lab_name, store_name, &problems
            ));
        }
        println!(
            "{} Loaded store '{}' ({})",
            style(">>>").green(),
            store_name,
            spec.backend_of(store_name).as_str(),
        );
        cache.insert(store_name.clone(), values);
    }

    let cache: SecretsCache = std::sync::Arc::new(cache);
    crate::host::state::project_host_secrets(host_projections, &cache, lab_name)?;

    Ok(Some(cache))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn binding(var: &str, secret: &str, key: &str) -> EnvVarBinding {
        EnvVarBinding {
            var: var.to_string(),
            secret: secret.to_string(),
            key: key.to_string(),
        }
    }

    #[test]
    fn a_set_variable_lands_under_its_secret_and_key() {
        let bindings = [binding("V", "session-key", "secret")];
        let values = read_env_store_with(&bindings, |_| Some("abc".to_string()));

        assert_eq!(values["session-key"]["secret"], "abc");
    }

    #[test]
    fn an_unset_variable_is_absent_rather_than_empty() {
        let bindings = [binding("V", "session-key", "secret")];
        let values = read_env_store_with(&bindings, |_| None);

        assert!(values.is_empty());
    }

    #[test]
    fn an_empty_variable_is_present_and_blank() {
        let bindings = [binding("V", "session-key", "secret")];
        let values = read_env_store_with(&bindings, |_| Some(String::new()));

        assert_eq!(values["session-key"]["secret"], "");
    }

    #[test]
    fn two_keys_of_one_secret_land_side_by_side() {
        let bindings = [
            binding("A", "lab-ca", "ca.crt"),
            binding("B", "lab-ca", "ca.key"),
        ];
        let values = read_env_store_with(&bindings, |var| Some(format!("{var}-value")));

        assert_eq!(values["lab-ca"]["ca.crt"], "A-value");
        assert_eq!(values["lab-ca"]["ca.key"], "B-value");
    }

    #[test]
    fn no_bindings_is_an_empty_store_and_not_an_error() {
        assert!(read_env_store_with(&[], |_| Some("x".to_string())).is_empty());
    }
}

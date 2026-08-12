use anyhow::{Result, bail};

use crate::config::Context as CataContext;
use crate::domain::secrets::{Backend, EnvVarBinding, SecretsSpec, StoreValues};

pub fn load_store(
    ctx: &CataContext,
    lab_name: &str,
    store: &str,
    spec: &SecretsSpec,
) -> Result<StoreValues> {
    match spec.backend_of(store) {
        Backend::Sops => {
            let path = crate::commands::secrets::store_file_path(ctx, lab_name, store);
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

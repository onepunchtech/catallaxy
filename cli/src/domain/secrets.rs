use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::error::CataError;

pub type StoreValues = HashMap<String, HashMap<String, String>>;
pub type SecretsCache = Arc<HashMap<String, StoreValues>>;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Backend {
    Sops,
    Env,
    Vault,
    External,
}

impl Backend {
    pub fn as_str(self) -> &'static str {
        match self {
            Backend::Sops => "sops",
            Backend::Env => "env",
            Backend::Vault => "vault",
            Backend::External => "external",
        }
    }

    pub fn readable_here(self) -> bool {
        matches!(self, Backend::Sops | Backend::Env)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SecretStore {
    pub backend: Backend,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SecretKind {
    #[default]
    Value,
    Ca,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ManagedKeyDef {
    pub generator: Option<String>,
    pub length: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ManagedSecret {
    pub store: String,
    #[serde(default)]
    pub kind: SecretKind,
    #[serde(default)]
    pub keys: BTreeMap<String, ManagedKeyDef>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SecretsSpec {
    #[serde(default)]
    pub stores: BTreeMap<String, SecretStore>,
    #[serde(default)]
    pub managed: BTreeMap<String, ManagedSecret>,
    #[serde(default)]
    pub env_file: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnvVarBinding {
    pub var: String,
    pub secret: String,
    pub key: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StoreProblem {
    MissingSecret { secret: String },
    MissingKey { secret: String, key: String },
    BlankKey { secret: String, key: String },
}

pub fn env_var_name(store: &str, secret: &str, key: &str) -> String {
    format!(
        "CATA_SECRET_{}__{}__{}",
        env_component(store),
        env_component(secret),
        env_component(key),
    )
}

fn env_component(part: &str) -> String {
    part.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() {
                c.to_ascii_uppercase()
            } else {
                '_'
            }
        })
        .collect()
}

impl SecretsSpec {
    pub fn from_lab_config(lab: &serde_json::Value) -> Result<Self, CataError> {
        match lab.get("secrets") {
            None => Ok(Self::default()),
            Some(value) => serde_json::from_value(value.clone()).map_err(|e| {
                CataError::Config(format!("lab.secrets is not a shape the CLI knows: {e}"))
            }),
        }
    }

    pub fn backend_of(&self, store: &str) -> Backend {
        self.stores
            .get(store)
            .map(|s| s.backend)
            .unwrap_or(Backend::Sops)
    }

    pub fn stores_with(&self, backend: Backend) -> Vec<&str> {
        self.stores
            .iter()
            .filter(|(_, s)| s.backend == backend)
            .map(|(name, _)| name.as_str())
            .collect()
    }

    pub fn store_of<'a>(&'a self, secret: &str) -> Option<&'a str> {
        self.managed.get(secret).map(|s| s.store.as_str())
    }

    pub fn secrets_in<'a>(&'a self, store: &str) -> Vec<(&'a str, &'a ManagedSecret)> {
        self.managed
            .iter()
            .filter(|(_, s)| s.store == store)
            .map(|(name, s)| (name.as_str(), s))
            .collect()
    }

    pub fn env_bindings(&self, store: &str) -> Vec<EnvVarBinding> {
        self.secrets_in(store)
            .into_iter()
            .flat_map(|(secret_name, secret)| {
                secret.keys.keys().map(move |key| EnvVarBinding {
                    var: env_var_name(store, secret_name, key),
                    secret: secret_name.to_string(),
                    key: key.clone(),
                })
            })
            .collect()
    }
}

pub fn validate_store(spec: &SecretsSpec, store: &str, values: &StoreValues) -> Vec<StoreProblem> {
    let mut problems = Vec::new();

    for (secret_name, secret) in spec.secrets_in(store) {
        let Some(present) = values.get(secret_name) else {
            problems.push(StoreProblem::MissingSecret {
                secret: secret_name.to_string(),
            });
            continue;
        };
        for key in secret.keys.keys() {
            match present.get(key) {
                None => problems.push(StoreProblem::MissingKey {
                    secret: secret_name.to_string(),
                    key: key.clone(),
                }),
                Some(value) if value.is_empty() => problems.push(StoreProblem::BlankKey {
                    secret: secret_name.to_string(),
                    key: key.clone(),
                }),
                Some(_) => {}
            }
        }
    }

    problems
}

pub fn describe_store_problems(
    spec: &SecretsSpec,
    lab_name: &str,
    store: &str,
    problems: &[StoreProblem],
) -> String {
    match spec.backend_of(store) {
        Backend::Env => describe_env_problems(spec, lab_name, store, problems),
        _ => describe_file_problems(spec, lab_name, store, problems),
    }
}

fn describe_env_problems(
    spec: &SecretsSpec,
    lab_name: &str,
    store: &str,
    problems: &[StoreProblem],
) -> String {
    let mut msg = format!(
        "Store '{store}' takes its values from the environment, and these are not set:\n\n"
    );

    for problem in problems {
        match problem {
            StoreProblem::MissingSecret { secret } => {
                let secret_keys = spec
                    .managed
                    .get(secret)
                    .map(|s| s.keys.keys().cloned().collect::<Vec<_>>())
                    .unwrap_or_default();
                for key in secret_keys {
                    msg.push_str(&format!(
                        "  {}   secret '{secret}', key '{key}'\n",
                        env_var_name(store, secret, &key),
                    ));
                }
            }
            StoreProblem::MissingKey { secret, key } => msg.push_str(&format!(
                "  {}   secret '{secret}', key '{key}'\n",
                env_var_name(store, secret, key),
            )),
            StoreProblem::BlankKey { secret, key } => msg.push_str(&format!(
                "  {} is set but empty   secret '{secret}', key '{key}'\n",
                env_var_name(store, secret, key),
            )),
        }
    }

    match spec.env_file.as_deref() {
        Some(file) => msg.push_str(&format!(
            "\n{lab_name} names the file that sets them:\n\n  {file}\n\n\
             Load it into this shell and run again:\n\n  set -a; . {file}; set +a\n",
        )),
        None => msg.push_str(&format!(
            "\n{lab_name} names no lab.secrets.envFile, so export them yourself, \
             or set lab.secrets.envFile to a file that does.\n",
        )),
    }

    msg
}

fn describe_file_problems(
    spec: &SecretsSpec,
    lab_name: &str,
    store: &str,
    problems: &[StoreProblem],
) -> String {
    let backend = spec.backend_of(store).as_str();
    let mut msg = format!("Store '{store}' is missing values declared in lab.secrets.managed:\n");

    for problem in problems {
        match problem {
            StoreProblem::MissingSecret { secret } => msg.push_str(&format!(
                "  - secret '{secret}' (no entry in the {backend} store)\n"
            )),
            StoreProblem::MissingKey { secret, key } => {
                msg.push_str(&format!("  - secret '{secret}': missing key '{key}'\n"))
            }
            StoreProblem::BlankKey { secret, key } => msg.push_str(&format!(
                "  - secret '{secret}': key '{key}' is empty (operator-supplied, fill it in)\n"
            )),
        }
    }

    msg.push_str(&format!(
        "\nRun:\n  cata secrets generate   # mint values for generator-backed keys\n  \
         cata secrets edit {lab_name} {store}   # fill operator-supplied keys"
    ));
    msg
}

pub fn describe_store_source(spec: &SecretsSpec, lab_name: &str, store: &str) -> String {
    match spec.backend_of(store) {
        Backend::Env => match spec.env_file.as_deref() {
            Some(file) => format!(
                "Store '{store}' takes its values from the environment, which {lab_name} fills from {file}."
            ),
            None => format!("Store '{store}' takes its values from the environment."),
        },
        _ => format!("Run `cata secrets edit {lab_name} {store}` to add it."),
    }
}

pub fn describe_missing_value(
    spec: &SecretsSpec,
    lab_name: &str,
    store: &str,
    secret: &str,
    key: &str,
) -> String {
    let head = format!("key '{key}' of managed secret '{secret}' (store '{store}') is missing");
    match spec.backend_of(store) {
        Backend::Env => format!(
            "{head}. Store '{store}' takes its values from the environment, so set {}.",
            env_var_name(store, secret, key),
        ),
        _ => format!("{head}. Run `cata secrets edit {lab_name} {store}` to add it."),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec_from(json: serde_json::Value) -> SecretsSpec {
        SecretsSpec::from_lab_config(&json).expect("spec parses")
    }

    fn gitops_spec() -> SecretsSpec {
        spec_from(serde_json::json!({
            "secrets": {
                "envFile": "/nix/store/abc-source/examples/labs/gitops/envs/ci.env",
                "stores": { "app": { "backend": "env" } },
                "managed": {
                    "session-key": {
                        "store": "app",
                        "kind": "value",
                        "keys": { "secret": { "generator": "base64", "length": 32 } }
                    }
                }
            }
        }))
    }

    #[test]
    fn env_var_name_uppercases_and_double_underscores() {
        assert_eq!(
            env_var_name("app", "session-key", "secret"),
            "CATA_SECRET_APP__SESSION_KEY__SECRET"
        );
    }

    #[test]
    fn env_var_name_replaces_every_character_that_is_not_a_letter_or_digit() {
        assert_eq!(
            env_var_name("my.store", "a b/c", "tls.crt"),
            "CATA_SECRET_MY_STORE__A_B_C__TLS_CRT"
        );
    }

    #[test]
    fn env_var_name_keeps_its_three_components_apart() {
        assert_ne!(
            env_var_name("a_b", "c", "k"),
            env_var_name("a", "b_c", "k"),
            "the double underscore is what stops these colliding"
        );
    }

    #[test]
    fn backend_of_an_undeclared_store_is_sops() {
        let spec = spec_from(serde_json::json!({ "secrets": { "stores": {} } }));
        assert_eq!(spec.backend_of("nothing-declares-me"), Backend::Sops);
    }

    #[test]
    fn a_lab_with_no_secrets_block_parses_to_an_empty_spec() {
        let spec = spec_from(serde_json::json!({ "name": "minimal.local" }));
        assert!(spec.stores.is_empty());
        assert!(spec.managed.is_empty());
        assert_eq!(spec.env_file, None);
    }

    #[test]
    fn the_metadata_shape_parses_without_kind_or_env_file() {
        let spec = spec_from(serde_json::json!({
            "secrets": {
                "stores": { "app": { "backend": "sops" } },
                "managed": { "session-key": { "store": "app", "keys": {} } }
            }
        }));
        assert_eq!(spec.managed["session-key"].kind, SecretKind::Value);
    }

    #[test]
    fn env_bindings_name_one_variable_per_key() {
        let bindings = gitops_spec().env_bindings("app");
        assert_eq!(bindings.len(), 1);
        assert_eq!(bindings[0].var, "CATA_SECRET_APP__SESSION_KEY__SECRET");
        assert_eq!(bindings[0].secret, "session-key");
        assert_eq!(bindings[0].key, "secret");
    }

    #[test]
    fn validate_store_tells_a_missing_key_from_a_blank_one() {
        let spec = gitops_spec();

        let missing = validate_store(&spec, "app", &StoreValues::from([]));
        assert_eq!(
            missing,
            vec![StoreProblem::MissingSecret {
                secret: "session-key".to_string()
            }]
        );

        let no_key = validate_store(
            &spec,
            "app",
            &StoreValues::from([("session-key".to_string(), HashMap::new())]),
        );
        assert_eq!(
            no_key,
            vec![StoreProblem::MissingKey {
                secret: "session-key".to_string(),
                key: "secret".to_string()
            }]
        );

        let blank = validate_store(
            &spec,
            "app",
            &StoreValues::from([(
                "session-key".to_string(),
                HashMap::from([("secret".to_string(), String::new())]),
            )]),
        );
        assert_eq!(
            blank,
            vec![StoreProblem::BlankKey {
                secret: "session-key".to_string(),
                key: "secret".to_string()
            }]
        );
    }

    #[test]
    fn the_env_message_names_the_variable_and_the_file() {
        let spec = gitops_spec();
        let problems = validate_store(&spec, "app", &StoreValues::from([]));
        let msg = describe_store_problems(&spec, "gitops.local", "app", &problems);

        assert!(
            msg.contains("CATA_SECRET_APP__SESSION_KEY__SECRET"),
            "{msg}"
        );
        assert!(msg.contains("ci.env"), "{msg}");
        assert!(msg.contains("set -a"), "{msg}");
    }

    #[test]
    fn the_env_message_says_so_when_the_lab_names_no_file() {
        let mut spec = gitops_spec();
        spec.env_file = None;
        let problems = validate_store(&spec, "app", &StoreValues::from([]));
        let msg = describe_store_problems(&spec, "gitops.local", "app", &problems);

        assert!(msg.contains("names no lab.secrets.envFile"), "{msg}");
    }

    #[test]
    fn the_sops_message_still_points_at_secrets_edit() {
        let spec = spec_from(serde_json::json!({
            "secrets": {
                "stores": { "trust": { "backend": "sops" } },
                "managed": { "lab-ca": { "store": "trust", "keys": { "ca.crt": {} } } }
            }
        }));
        let problems = validate_store(&spec, "trust", &StoreValues::from([]));
        let msg = describe_store_problems(&spec, "mesh.local", "trust", &problems);

        assert!(msg.contains("cata secrets edit mesh.local trust"), "{msg}");
        assert!(!msg.contains("CATA_SECRET"), "{msg}");
    }

    #[test]
    fn describe_missing_value_names_the_variable_for_an_env_store() {
        let spec = gitops_spec();
        let msg = describe_missing_value(&spec, "gitops.local", "app", "session-key", "secret");
        assert!(
            msg.contains("CATA_SECRET_APP__SESSION_KEY__SECRET"),
            "{msg}"
        );
    }
}

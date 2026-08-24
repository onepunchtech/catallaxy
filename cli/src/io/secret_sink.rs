use std::io::Write;
use std::process::{Command, Stdio};

use anyhow::{Context, Result, bail};

use crate::domain::secrets::{Backend, SecretStore};

/// Somewhere the host can write a value it only learned at runtime.
///
/// An interface rather than a fixed backend, because which store a lab writes
/// to is the operator's decision and not a set catallaxy can enumerate. Two
/// implementations ship: a store spoken to over Vault's API, and a command,
/// which is what makes the set open.
pub enum SecretSink {
    Vault(VaultSink),
    Command(CommandSink),
}

impl SecretSink {
    /// # Errors
    ///
    /// If the value could not be written.
    pub async fn write(&self, key: &str, value: &str) -> Result<()> {
        match self {
            Self::Vault(s) => s.write(key, value).await,
            Self::Command(s) => s.write(key, value),
        }
    }

    /// How to describe this sink when saying where a value went.
    pub fn describe(&self) -> String {
        match self {
            Self::Vault(s) => s.describe(),
            Self::Command(s) => s.describe(),
        }
    }
}

/// # Errors
///
/// If the store cannot be written to, which is a question about the lab's
/// declaration rather than about this moment: an `authored` store has no
/// writer by definition, and an `external` one without a command says only
/// that it is managed elsewhere.
pub fn for_store(name: &str, store: &SecretStore) -> Result<SecretSink> {
    if let Some(argv) = store.writer_command.as_ref() {
        if argv.is_empty() {
            bail!(
                "store '{name}' declares an empty `writer.command`, so there is \
                 nothing to run. Give it the argv that writes one value, or \
                 remove the field."
            );
        }
        return Ok(SecretSink::Command(CommandSink {
            store: name.to_string(),
            argv: argv.clone(),
        }));
    }

    match store.backend {
        Backend::Vault => {
            let server = store.vault.server.as_deref().ok_or_else(|| {
                anyhow::anyhow!(
                    "store '{name}' is a vault store with no `vault.server`, so \
                     there is no address to write to."
                )
            })?;
            let token = std::env::var("VAULT_TOKEN").map_err(|_| {
                anyhow::anyhow!(
                    "store '{name}' needs $VAULT_TOKEN to write to {server}.\n    \
                     The token is read from the environment rather than the lab, \
                     so it never reaches the rendered output or the state file."
                )
            })?;
            Ok(SecretSink::Vault(VaultSink {
                store: name.to_string(),
                server: server.to_string(),
                mount: store.vault.path.clone(),
                v2: store.vault.version == "v2",
                token,
            }))
        }
        Backend::External => bail!(
            "store '{name}' is an `external` store with no `writer.command`.\n    \
             `external` on its own says the store is managed outside catallaxy, \
             which is not something to write through. Give it the command that \
             writes one value."
        ),
        Backend::Sops | Backend::Env => bail!(
            "store '{name}' is an authored store, so nothing writes to it at \
             runtime.\n    An authored store holds values you wrote, and for \
             sops that is a file in your repository. Publish to a `vault` or \
             `external` store instead."
        ),
    }
}

pub struct VaultSink {
    store: String,
    server: String,
    mount: String,
    v2: bool,
    token: String,
}

impl VaultSink {
    async fn write(&self, key: &str, value: &str) -> Result<()> {
        // KV v2 nests the payload under `data` and puts `data` in the path as
        // well. Writing a v2 mount as though it were v1 succeeds and stores
        // the wrong shape, which nothing notices until a reader gets an
        // envelope where it expected a value.
        let (path, body) = if self.v2 {
            (
                format!("{}/v1/{}/data/{key}", self.server, self.mount),
                serde_json::json!({ "data": { "value": value } }),
            )
        } else {
            (
                format!("{}/v1/{}/{key}", self.server, self.mount),
                serde_json::json!({ "value": value }),
            )
        };

        let response = crate::io::http::client(reqwest::Client::builder())?
            .post(&path)
            .header("X-Vault-Token", &self.token)
            .json(&body)
            .send()
            .await
            .with_context(|| format!("writing '{key}' to {}", self.describe()))?;

        if !response.status().is_success() {
            bail!(
                "{} refused the write of '{key}': HTTP {}.",
                self.describe(),
                response.status(),
            );
        }
        Ok(())
    }

    fn describe(&self) -> String {
        format!("store '{}' ({}/{})", self.store, self.server, self.mount)
    }
}

pub struct CommandSink {
    store: String,
    argv: Vec<String>,
}

impl CommandSink {
    fn write(&self, key: &str, value: &str) -> Result<()> {
        // The value goes on stdin and the key in the environment. Neither is
        // an argument, so neither shows up in a process listing on a shared
        // machine.
        let mut child = Command::new(&self.argv[0])
            .args(&self.argv[1..])
            .env("CATA_SECRET_KEY", key)
            .stdin(Stdio::piped())
            .spawn()
            .with_context(|| format!("running the writer for {}", self.describe()))?;

        child
            .stdin
            .as_mut()
            .expect("stdin was piped")
            .write_all(value.as_bytes())
            .with_context(|| format!("sending '{key}' to {}", self.describe()))?;

        let status = child
            .wait()
            .with_context(|| format!("waiting for the writer of {}", self.describe()))?;

        if !status.success() {
            bail!(
                "the writer for {} exited {} writing '{key}'.\n    \
                 It ran as: {}",
                self.describe(),
                status.code().unwrap_or(-1),
                self.argv.join(" "),
            );
        }
        Ok(())
    }

    fn describe(&self) -> String {
        format!("store '{}'", self.store)
    }
}

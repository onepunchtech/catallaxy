use std::path::PathBuf;

use anyhow::{Context as _, Result};

#[derive(Debug, Clone)]
pub struct FlakeRef {
    pub uri: String,
    pub fragment: Option<String>,
}

impl FlakeRef {
    pub fn parse(input: &str) -> Result<Self> {
        let (uri_part, fragment) = match input.split_once('#') {
            Some((uri, frag)) => (uri, Some(frag.to_string())),
            None => (input, None),
        };

        let uri = if Self::is_remote(uri_part) {
            uri_part.to_string()
        } else {
            let path = PathBuf::from(uri_part)
                .canonicalize()
                .with_context(|| format!("Failed to resolve flake path: {uri_part}"))?;
            path.display().to_string()
        };

        Ok(Self { uri, fragment })
    }

    fn is_remote(uri: &str) -> bool {
        uri.contains("://")
            || uri.starts_with("github:")
            || uri.starts_with("git+")
            || uri.starts_with("gitlab:")
            || uri.starts_with("sourcehut:")
            || uri.starts_with("path:")
    }
}

#[derive(Clone)]
pub struct Context {
    pub flake_ref: FlakeRef,

    pub verbose: bool,
}

impl Context {
    pub fn new(flake: String, verbose: bool) -> Result<Self> {
        let flake_ref = FlakeRef::parse(&flake)?;

        Ok(Self { flake_ref, verbose })
    }

    pub fn flake_uri(&self) -> &str {
        &self.flake_ref.uri
    }

    pub fn resolve_cluster_name(&self, explicit: Option<&str>) -> Result<String> {
        match explicit.or(self.flake_ref.fragment.as_deref()) {
            Some(name) => Ok(name.to_string()),
            None => anyhow::bail!(
                "cluster name required: use --flake <ref>#<cluster>, \
                 or pass it as an argument"
            ),
        }
    }

    pub fn resolve_lab_name(&self, explicit: Option<&str>) -> Result<String> {
        match explicit.or(self.flake_ref.fragment.as_deref()) {
            Some(name) => {
                let _ = crate::io::trust::activate(name);
                Ok(name.to_string())
            }
            None => {
                anyhow::bail!(
                    "lab name required: use --flake <ref>#<lab>, \
                     or pass it as an argument"
                )
            }
        }
    }
}

//! Configuration and context for CLI operations

use std::path::PathBuf;

use anyhow::{Context as _, Result};

/// Parsed flake reference (URI + optional fragment)
#[derive(Debug, Clone)]
pub struct FlakeRef {
    /// The flake URI (path, github:..., git+ssh://..., etc.)
    pub uri: String,
    /// Optional fragment (cluster name from .#fragment)
    pub fragment: Option<String>,
}

impl FlakeRef {
    /// Parse a flake reference string, splitting on `#`
    pub fn parse(input: &str) -> Result<Self> {
        let (uri_part, fragment) = match input.split_once('#') {
            Some((uri, frag)) => (uri, Some(frag.to_string())),
            None => (input, None),
        };

        let uri = if Self::is_remote(uri_part) {
            uri_part.to_string()
        } else {
            // Local path — canonicalize
            let path = PathBuf::from(uri_part)
                .canonicalize()
                .with_context(|| format!("Failed to resolve flake path: {uri_part}"))?;
            path.display().to_string()
        };

        Ok(Self { uri, fragment })
    }

    /// Check if a URI is a remote flake reference
    fn is_remote(uri: &str) -> bool {
        uri.contains("://")
            || uri.starts_with("github:")
            || uri.starts_with("git+")
            || uri.starts_with("gitlab:")
            || uri.starts_with("sourcehut:")
            || uri.starts_with("path:")
    }
}

/// Runtime context for CLI commands
#[derive(Clone)]
pub struct Context {
    /// Parsed flake reference
    pub flake_ref: FlakeRef,

    /// Verbose output enabled
    pub verbose: bool,
}

impl Context {
    pub fn new(flake: String, verbose: bool) -> Result<Self> {
        let flake_ref = FlakeRef::parse(&flake)?;

        Ok(Self { flake_ref, verbose })
    }

    /// Get the flake URI for nix commands (without fragment)
    pub fn flake_uri(&self) -> &str {
        &self.flake_ref.uri
    }

    /// Resolve cluster name: explicit argument takes priority, then fragment
    pub fn resolve_cluster_name(&self, explicit: Option<&str>) -> Result<String> {
        match explicit.or(self.flake_ref.fragment.as_deref()) {
            Some(name) => Ok(name.to_string()),
            None => anyhow::bail!(
                "cluster name required (pass as argument or use --flake <ref>#<cluster>)"
            ),
        }
    }

    /// Resolve lab name: explicit argument takes priority, then fragment
    pub fn resolve_lab_name(&self, explicit: Option<&str>) -> Result<String> {
        match explicit.or(self.flake_ref.fragment.as_deref()) {
            Some(name) => Ok(name.to_string()),
            None => {
                anyhow::bail!("lab name required (pass as argument or use --flake <ref>#<lab>)")
            }
        }
    }
}

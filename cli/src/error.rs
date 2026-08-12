use std::io;
use std::path::PathBuf;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum CataError {
    #[error("configuration error: {0}")]
    Config(String),

    #[error("nix evaluation failed: {0}")]
    NixEval(String),

    #[error("required tool `{name}` not found in PATH")]
    ToolMissing { name: String },

    #[error("manifest error: {0}")]
    Manifest(String),

    #[error("io error at {}: {source}", path.as_ref().map_or("<unknown>".into(), |p| p.display().to_string()))]
    Io {
        path: Option<PathBuf>,
        #[source]
        source: io::Error,
    },

    #[error("`{command}` exited with status {status}: {stderr}")]
    Subprocess {
        command: String,
        status: i32,
        stderr: String,
    },

    #[error("kubernetes error: {0}")]
    Kubernetes(String),
}

impl From<io::Error> for CataError {
    fn from(source: io::Error) -> Self {
        CataError::Io { path: None, source }
    }
}

pub type CataResult<T> = std::result::Result<T, CataError>;

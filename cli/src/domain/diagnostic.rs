use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Severity {
    Error,
    Warning,
}

#[derive(Debug, Clone)]
pub struct Diagnostic {
    pub severity: Severity,
    pub check: &'static str,
    pub cluster: String,
    pub file: PathBuf,
    pub resource: String,
    pub message: String,
}

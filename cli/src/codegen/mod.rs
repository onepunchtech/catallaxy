//! Kubernetes API type code generation
//!
//! This module generates Nix module types from Kubernetes OpenAPI specs and CRDs.
//!
//! ## Architecture
//!
//! ```text
//! Nix (packages) → JSON (paths) → Rust (codegen) → Nix files (generated types)
//! ```
//!
//! The CLI receives JSON with paths to pre-packaged OpenAPI specs and CRD YAMLs
//! from Nix, reads them from disk, and generates Nix module type definitions.
//!
//! ## Modules
//!
//! - `types`: Internal type representation (NixType IR)
//! - `schema`: OpenAPI/JSON Schema parsing
//! - `nix_emitter`: Nix code generation with pretty printing
//! - `crd`: CRD YAML parsing

#[allow(dead_code)]
pub mod crd;
#[allow(dead_code)]
pub mod nix_emitter;
#[allow(dead_code)]
pub mod schema;
#[allow(dead_code)]
pub mod types;

pub use crd::parse_crds_from_yaml;
pub use nix_emitter::{EmitterConfig, emit_crd_types, emit_index, emit_k8s_types};
pub use schema::{convert_openapi_to_types, parse_openapi_spec};
pub use types::GeneratorOptions;

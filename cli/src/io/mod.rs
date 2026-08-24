//! Everything the CLI does to the world outside its own process.
//!
//! This is the layer where a `Result` is a claim about a subprocess, a file or
//! a cluster rather than about the CLI's own arithmetic, so `# Errors` is
//! where the distinctions live that a caller cannot see from the signature:
//! whether a non-zero exit is an error or an answer, whether a missing thing
//! counts as success, and which best-effort steps a returned `Ok` does not
//! promise. Denied here rather than in `cli/Cargo.toml` because the rest of
//! the crate has not been swept yet; move it there once it has.
#![deny(clippy::missing_errors_doc)]

pub mod chainsaw;
pub mod check_script;
pub mod clusterctl;
pub mod colima;
pub mod crane;
pub mod diff;
pub mod discovery;
pub mod docker;
pub mod egress;
pub mod fs;
pub mod git;
pub mod helm;
pub mod hook;
pub mod host_inventory;
pub mod http;
pub mod k3d;
pub mod k3d_node;
pub mod kapp;
pub mod kube_context;
pub mod kubeconfig;
pub mod kubectl;
pub mod net;
pub mod nix;
pub mod pki;
pub mod poll;
pub mod process;
pub mod route;
pub mod secret_sink;
pub mod secrets;
pub mod sops;
pub mod ssa;
pub mod sudo;
pub mod systemd;
pub mod talos;
pub mod tofu;
pub mod trust;
pub mod trust_store;
pub mod ykman;

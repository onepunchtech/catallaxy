use std::cell::RefCell;

use crate::config::Context as CataContext;
use crate::domain::SecretsCache;
use crate::domain::{BootstrapTool, DeployStrategy, LabSpec, StepFailure};

pub struct StepContext<'a> {
    pub ctx: &'a CataContext,

    /// The kubectl this step runs. Held as a trait object so a test can hand
    /// a step fake bytes instead of needing a cluster.
    pub kubectl: &'a dyn crate::io::kubectl::Kubectl,

    pub lab_name: &'a str,

    pub lab: &'a LabSpec,

    pub lab_package: &'a str,

    pub secrets_cache: Option<SecretsCache>,

    pub strategy: DeployStrategy,

    pub bootstrap: BootstrapTool,

    pub dry_run: bool,

    /// Whether a step that creates or destroys real infrastructure may run.
    ///
    /// Off unless asked for. A cluster can be thrown away and rebuilt; a
    /// cloud account cannot, so the two do not get the same default.
    pub allow_infra: bool,

    pub failures: RefCell<Vec<StepFailure>>,
}

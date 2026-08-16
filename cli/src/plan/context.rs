use std::cell::RefCell;

use crate::config::Context as CataContext;
use crate::domain::SecretsCache;
use crate::domain::{BootstrapTool, DeployStrategy, LabSpec, StepFailure};

pub struct StepContext<'a> {
    pub ctx: &'a CataContext,

    pub lab_name: &'a str,

    pub lab: &'a LabSpec,

    pub lab_package: &'a str,

    pub secrets_cache: Option<SecretsCache>,

    pub strategy: DeployStrategy,

    pub bootstrap: BootstrapTool,

    pub dry_run: bool,

    pub failures: RefCell<Vec<StepFailure>>,
}

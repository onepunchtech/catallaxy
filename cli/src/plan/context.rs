use std::cell::RefCell;

use crate::commands::apply::SecretsCache;
use crate::config::Context as CataContext;

pub struct StepContext<'a> {
    pub ctx: &'a CataContext,

    pub lab_name: &'a str,

    pub lab: &'a serde_json::Value,

    pub lab_package: &'a str,

    pub secrets_cache: Option<SecretsCache>,

    pub strategy: &'a str,

    pub bootstrap: &'a str,

    pub dry_run: bool,

    pub failures: RefCell<Vec<String>>,
}

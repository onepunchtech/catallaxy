use anyhow::{Result, bail};
use console::style;

use crate::domain::plan::EnsureSecretsParams;
use crate::domain::secrets::{Backend, describe_store_problems, validate_store};
use crate::plan::StepContext;

pub fn run(sctx: &StepContext<'_>, p: &EnsureSecretsParams) -> Result<()> {
    let EnsureSecretsParams { stores } = p;

    let spec = &sctx.lab.secrets;

    for store_name in stores {
        if sctx
            .secrets_cache
            .as_ref()
            .is_some_and(|cache| cache.contains_key(store_name))
        {
            println!(
                "{} Store '{}' ready (loaded in preflight)",
                style(">>>").green(),
                store_name,
            );
            continue;
        }

        match spec.backend_of(store_name) {
            Backend::Sops => {
                let enc_path =
                    crate::io::secrets::store_file_path(sctx.ctx, sctx.lab_name, store_name);
                if !enc_path.exists() {
                    bail!(
                        "Secret store '{store_name}' is not at {}.\nRun these commands first:\n  \
                         cata secrets generate\n  cata secrets edit {store_name}",
                        enc_path.display(),
                    );
                }
                println!("{} Store '{}' exists", style(">>>").green(), store_name);
            }
            Backend::Env => {
                let bindings = spec.env_bindings(store_name);
                let values = crate::io::secrets::read_env_store(&bindings);
                let problems = validate_store(spec, store_name, &values);
                if !problems.is_empty() {
                    bail!(describe_store_problems(
                        spec,
                        sctx.lab_name,
                        store_name,
                        &problems
                    ));
                }
                println!(
                    "{} Store '{}' ready ({} value(s) from the environment)",
                    style(">>>").green(),
                    store_name,
                    bindings.len(),
                );
            }
            backend => println!(
                "{} Store '{}' has backend {}, which catallaxy does not manage",
                style(">>>").yellow(),
                store_name,
                backend.as_str(),
            ),
        }
    }

    Ok(())
}

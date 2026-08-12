use std::process::Command;

use anyhow::{Context, Result, bail};
use console::style;

use crate::domain::plan::ScriptEnv;
use crate::plan::StepContext;

pub fn run(
    sctx: &StepContext<'_>,
    bin: &str,
    lifecycle_name: Option<&str>,
    env: &[ScriptEnv],
    kube_context: Option<&str>,
    continue_on_failure: bool,
) -> Result<()> {
    let hook_name = lifecycle_name.unwrap_or("<unnamed>");
    if bin.is_empty() {
        bail!("run-script step '{hook_name}' has no `bin` field");
    }
    println!("{} hook '{}'", style(">>>").cyan(), style(hook_name).bold(),);

    if !std::path::Path::new(bin).exists() {
        let msg = format!(
            "hook binary not in the nix store:\n    {bin}\n    \
             The lab package build failed or was skipped, so the hook was \
             never realized. Run `nix build .#labPackages.\"{}\"` and retry.",
            sctx.lab_name,
        );
        if continue_on_failure {
            println!("{} {hook_name} skipped: {msg}", style("ERROR").red());
            sctx.failures.borrow_mut().push(format!(
                "run-script {hook_name}: binary not realized ({bin})"
            ));
            return Ok(());
        }
        bail!("Lifecycle hook '{hook_name}' cannot run: {msg}");
    }

    let resolved = resolve_env(sctx, hook_name, env)?;

    let mut cmd = Command::new(bin);
    crate::io::trust::apply(&mut cmd);
    for (name, value) in &resolved {
        cmd.env(name, value);
    }
    if let Some(ctx) = kube_context {
        cmd.env("KUBECONTEXT", ctx);
    }
    let status = cmd
        .status()
        .with_context(|| format!("executing lifecycle hook '{hook_name}' ({bin})"))?;
    if !status.success() {
        let code = status.code().unwrap_or(-1);
        if continue_on_failure {
            println!(
                "{} hook '{hook_name}' failed (exit {code}), continuing",
                style("ERROR").red(),
            );
            sctx.failures
                .borrow_mut()
                .push(format!("run-script {hook_name} (exit {code})"));
            return Ok(());
        }
        bail!(
            "Lifecycle hook '{hook_name}' failed. \
             Bin: {bin}. Fix the hook or its precondition and re-run \
             `cata lab up`."
        );
    }
    println!("{} hook '{}' ok", style(">>>").green(), hook_name);
    Ok(())
}

fn resolve_env(
    sctx: &StepContext<'_>,
    hook_name: &str,
    env: &[ScriptEnv],
) -> Result<Vec<(String, String)>> {
    if env.is_empty() {
        return Ok(Vec::new());
    }

    let Some(cache) = sctx.secrets_cache.as_ref() else {
        bail!(
            "Lifecycle hook '{hook_name}' declares {} secret-sourced \
             environment variable(s), but no secret stores were decrypted \
             for this lab. Declare the store under `lab.secrets.stores` so \
             the executor decrypts it before the plan runs.",
            env.len(),
        );
    };

    env.iter()
        .map(|e| {
            let store = sctx
                .lab
                .pointer(&format!("/secrets/managed/{}/store", e.secret))
                .and_then(|v| v.as_str())
                .unwrap_or(&e.secret);

            let value = cache
                .get(store)
                .and_then(|secrets| secrets.get(&e.secret))
                .and_then(|keys| keys.get(&e.key))
                .ok_or_else(|| {
                    anyhow::anyhow!(
                        "Lifecycle hook '{hook_name}' needs ${}, sourced from \
                         key '{}' of managed secret '{}' (store '{}'), but that \
                         value is not in the decrypted store cache. Check that \
                         `lab.secrets.managed.{}` declares key '{}', and that \
                         the store's SOPS file carries it.",
                        e.name,
                        e.key,
                        e.secret,
                        store,
                        e.secret,
                        e.key,
                    )
                })?;
            Ok((e.name.clone(), value.clone()))
        })
        .collect()
}

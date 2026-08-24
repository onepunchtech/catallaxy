use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use console::style;

use crate::domain::plan::InfraParams;
use crate::io::tofu;
use crate::plan::StepContext;

/// What the tool is called inside the lab package.
///
/// The lab carries its own, built with exactly the providers its stacks pin,
/// so nothing here looks on `PATH` or reasons about versions.
const TOOL: &str = "infra/bin/tofu";

struct Stack {
    name: String,
    tool: PathBuf,
    rendered: PathBuf,
    work_dir: PathBuf,
}

impl Stack {
    fn resolve(sctx: &StepContext<'_>, p: &InfraParams) -> Result<Self> {
        let package = Path::new(sctx.lab_package);
        let tool = package.join(TOOL);
        let rendered = package.join("infra").join(&p.stack).join("main.tf.json");

        if !tofu::exists(&tool) {
            bail!(
                "This lab package carries no provisioning tool, so stack '{}' \
                 cannot run.\n    Looked for: {}\n    \
                 The tool is built from the providers the lab's stacks pin, so \
                 a package built before the stack existed will not have it. \
                 Rebuild with `nix build .#labPackages.\"{}\"` and retry.",
                p.stack,
                tool.display(),
                sctx.lab_name,
            );
        }

        if !tofu::exists(&rendered) {
            bail!(
                "Stack '{}' is not in this lab package.\n    Looked for: {}\n    \
                 The plan names a stack the package does not render, which \
                 means the two came from different evaluations. Rebuild with \
                 `nix build .#labPackages.\"{}\"` and retry.",
                p.stack,
                rendered.display(),
                sctx.lab_name,
            );
        }

        let work_dir = match p.working_dir.as_deref() {
            Some(dir) => PathBuf::from(dir),
            None => crate::host::state::infra_work_dir(sctx.lab_name, &p.stack),
        };

        Ok(Self {
            name: p.stack.clone(),
            tool,
            rendered,
            work_dir,
        })
    }

    /// Stage what the lab rendered and initialise.
    ///
    /// `init` runs every time. It is offline against the pinned providers and
    /// cheap, and skipping it is how a changed provider set turns into a
    /// confusing failure three commands later.
    fn prepare(&self) -> Result<()> {
        tofu::stage(&self.rendered, &self.work_dir)?;
        self.run("init", &["-input=false"])
    }

    fn run(&self, verb: &str, args: &[&str]) -> Result<()> {
        let status = tofu::run(&self.tool, &self.work_dir, verb, args)?;
        if !status.success() {
            bail!(self.failed(verb, args, status.code()));
        }
        Ok(())
    }

    /// The message an operator acts on.
    ///
    /// It names the stack, where the tool ran, and the exact command to repeat
    /// by hand, because the next thing anyone does with a failed apply is run
    /// it again themselves to read the whole output.
    fn failed(&self, verb: &str, args: &[&str], code: Option<i32>) -> String {
        format!(
            "Stack '{}' failed at `{}` (exit {}).\n\n    \
             The tool ran in:\n      {}\n\n    \
             To see the whole output, or to retry by hand:\n      \
             cd {} && {} {} {}\n\n    \
             State is in that directory and was not discarded, so a partial \
             apply is still recorded and a retry continues from it.",
            self.name,
            verb,
            code.map(|c| c.to_string())
                .unwrap_or_else(|| "signal".into()),
            self.work_dir.display(),
            self.work_dir.display(),
            self.tool.display(),
            verb,
            args.join(" "),
        )
    }
}

pub fn plan(sctx: &StepContext<'_>, p: &InfraParams) -> Result<()> {
    let stack = Stack::resolve(sctx, p)?;
    println!(
        "{} planning stack '{}'",
        style(">>>").cyan(),
        style(&stack.name).bold(),
    );
    stack.prepare()?;
    stack.run("plan", &["-input=false", "-no-color"])
}

pub async fn apply(sctx: &StepContext<'_>, p: &InfraParams) -> Result<()> {
    let stack = Stack::resolve(sctx, p)?;

    if !sctx.allow_infra {
        println!(
            "{} stack '{}' not applied. It creates and destroys real \
             infrastructure, so it runs only when asked for.\n      \
             Pass `--infra` to `cata lab up` to apply it, or run \
             `cata lab plan` to see what it would change.",
            style("skipped").yellow(),
            style(&stack.name).bold(),
        );
        return Ok(());
    }

    println!(
        "{} applying stack '{}'",
        style(">>>").cyan(),
        style(&stack.name).bold(),
    );
    stack.prepare()?;
    stack.run("apply", &["-input=false", "-auto-approve", "-no-color"])?;
    let outputs = capture_outputs(&stack)?;
    publish(sctx, &stack, &outputs).await?;
    println!(
        "{} stack '{}' applied",
        style(">>>").green(),
        style(&stack.name).bold(),
    );
    Ok(())
}

pub fn destroy(sctx: &StepContext<'_>, p: &InfraParams) -> Result<()> {
    let stack = Stack::resolve(sctx, p)?;

    if !sctx.allow_infra {
        println!(
            "{} stack '{}' not destroyed. Pass `--infra` to destroy it; \
             what it created is still there.",
            style("skipped").yellow(),
            style(&stack.name).bold(),
        );
        return Ok(());
    }

    println!(
        "{} destroying stack '{}'",
        style(">>>").cyan(),
        style(&stack.name).bold(),
    );
    stack.prepare()?;
    stack.run("destroy", &["-input=false", "-auto-approve", "-no-color"])
}

/// Record what the apply produced, next to the state that produced it.
///
/// Outputs are only knowable after an apply, so this is the one moment they
/// exist. Written to a file rather than held in memory because the next thing
/// that wants them is usually a different command.
fn capture_outputs(stack: &Stack) -> Result<serde_json::Value> {
    let out = tofu::capture(&stack.tool, &stack.work_dir, "output", &["-json"])?;

    if !out.status.success() {
        bail!(
            "Stack '{}' applied, but its outputs could not be read.\n    {}\n    \
             The apply itself succeeded, so nothing needs undoing; anything \
             waiting on an output will not see it until this is fixed.",
            stack.name,
            String::from_utf8_lossy(&out.stderr).trim(),
        );
    }

    tofu::write_outputs(&stack.work_dir, &out.stdout)?;
    serde_json::from_slice(&out.stdout)
        .with_context(|| format!("parsing the outputs of stack '{}'", stack.name))
}

/// Put what the stack produced where the lab said to.
///
/// A cluster reads it back with `secrets.subscribe`, so this is the only hop
/// that is not already someone else's: the value exists on this host for the
/// length of one apply and has to be handed on before it is gone.
async fn publish(sctx: &StepContext<'_>, stack: &Stack, outputs: &serde_json::Value) -> Result<()> {
    let wanted: Vec<_> = sctx
        .lab
        .infra_publications
        .iter()
        .filter(|p| p.stack == stack.name)
        .collect();

    for target in wanted {
        let value = outputs
            .get(&target.output_name)
            .and_then(|o| o.get("value"))
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| {
                anyhow::anyhow!(
                    "stack '{}' was to publish '{}' as '{}', and the apply \
                     produced no such output.\n    \
                     The stack renders an output per declared attribute, so \
                     this means the two came from different evaluations. \
                     Rebuild the lab package and retry.",
                    stack.name,
                    target.output_name,
                    target.key,
                )
            })?;

        let store = sctx.lab.secrets.stores.get(&target.store).ok_or_else(|| {
            anyhow::anyhow!(
                "stack '{}' publishes to store '{}', which this lab does not \
                 declare.",
                stack.name,
                target.store,
            )
        })?;

        let sink = crate::io::secret_sink::for_store(&target.store, store)?;
        sink.write(&target.key, value).await?;
        println!(
            "{} published '{}' to {}",
            style(">>>").green(),
            target.key,
            sink.describe(),
        );
    }
    Ok(())
}

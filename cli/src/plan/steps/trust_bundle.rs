use anyhow::{Result, bail};
use console::style;

use crate::io::trust::{self, Outcome};
use crate::plan::StepContext;

pub fn run(sctx: &StepContext<'_>) -> Result<()> {
    if sctx.dry_run {
        println!(
            "{} [dry-run] would build the CA trust bundle for '{}'",
            style(">>>").yellow(),
            sctx.lab_name,
        );
        return Ok(());
    }

    match trust::activate(sctx.lab_name)? {
        Outcome::Ready(path) => {
            println!(
                "{} Lab CA trusted by spawned tools ({})",
                style(">>>").green(),
                path.display(),
            );
            Ok(())
        }
        Outcome::NoLabCa => bail!(
            "No lab CA at {}.\n    \
             Expected either a `cert-generate` step (labs with a proxy that \
             terminates TLS) or a `kind = \"ca\"` managed secret whose \
             `hostPaths` project it there. If this lab declares one, run \
             `cata secrets generate` to mint it.",
            trust::lab_ca_path(sctx.lab_name).display(),
        ),
        Outcome::NoSystemRoots => {
            println!(
                "{} Could not find a public CA bundle to merge the lab CA into, \
                 so spawned tools keep the host's trust unchanged.\n    \
                 A lab-CA-only bundle is deliberately not written — it would \
                 break every public HTTPS call. Install `cata` through nix (it \
                 provides one), or expose one at $CATALLAXY_SYSTEM_CA_BUNDLE.",
                style("Warning:").yellow(),
            );
            Ok(())
        }
    }
}

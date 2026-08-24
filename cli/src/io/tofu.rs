use std::path::Path;
use std::process::Command;

use anyhow::{Context, Result};

use crate::io::process::run_status;

/// Put what the lab rendered into the working directory.
///
/// The rendered file is in the nix store and read-only; the tool needs a
/// directory it can write state and a provider lock into. Copying every run is
/// what makes a rebuilt lab take effect.
///
/// # Errors
///
/// If the directory cannot be made or the file cannot be copied.
pub fn stage(rendered: &Path, work_dir: &Path) -> Result<()> {
    crate::io::fs::create_dir_all(work_dir)
        .with_context(|| format!("creating {}", work_dir.display()))?;

    // Read and write rather than copy. The source is in the nix store and so
    // is read-only, and `fs::copy` carries the mode across: the first run
    // would leave a 0444 file that the second run cannot write, failing as a
    // permission error naming a path the operator never chose. Removing first
    // because writing over a read-only file fails the same way.
    let target = work_dir.join("main.tf.json");
    if target.exists() {
        std::fs::remove_file(&target).with_context(|| format!("replacing {}", target.display()))?;
    }
    let rendered_bytes =
        std::fs::read(rendered).with_context(|| format!("reading {}", rendered.display()))?;
    std::fs::write(&target, rendered_bytes)
        .with_context(|| format!("writing {}", target.display()))?;
    Ok(())
}

/// # Errors
///
/// Only if the tool cannot be spawned. A refused plan or a failed apply is a
/// non-zero `ExitStatus`, with the tool's own output already on the terminal.
pub fn run(
    tool: &Path,
    work_dir: &Path,
    verb: &str,
    args: &[&str],
) -> Result<std::process::ExitStatus> {
    run_status(&mut command(tool, work_dir, verb, args))
        .with_context(|| format!("running {} {verb}", tool.display()))
}

/// Read the tool's output as bytes rather than letting it reach the terminal.
///
/// # Errors
///
/// If the tool cannot be spawned.
pub fn capture(
    tool: &Path,
    work_dir: &Path,
    verb: &str,
    args: &[&str],
) -> Result<std::process::Output> {
    command(tool, work_dir, verb, args)
        .output()
        .with_context(|| format!("running {} {verb}", tool.display()))
}

/// # Errors
///
/// If the file cannot be written.
pub fn write_outputs(work_dir: &Path, json: &[u8]) -> Result<()> {
    let path = work_dir.join("outputs.json");
    std::fs::write(&path, json).with_context(|| format!("writing {}", path.display()))
}

/// What a stack's state records, or none when there is no state yet.
///
/// Reads the state through the tool rather than parsing the file, because
/// where the file lives depends on the backend and only the tool knows.
///
/// # Errors
///
/// If the tool cannot be spawned.
pub fn resources_in_state(tool: &Path, work_dir: &Path) -> Result<Vec<String>> {
    let out = capture(tool, work_dir, "state", &["list"])?;
    if !out.status.success() {
        return Ok(Vec::new());
    }
    Ok(String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .map(ToString::to_string)
        .collect())
}

pub fn exists(path: &Path) -> bool {
    path.exists()
}

fn command(tool: &Path, work_dir: &Path, verb: &str, args: &[&str]) -> Command {
    let mut cmd = Command::new(tool);
    cmd.arg(verb)
        .args(args)
        .current_dir(work_dir)
        .env("TF_IN_AUTOMATION", "1");
    cmd
}

/// What a lab's stacks still record, read from local state files.
///
/// Reads the files rather than asking the tool, because this runs from
/// salvage commands where the lab may no longer be in the flake and there may
/// be no package to get a tool from. A stack with a remote backend keeps no
/// local state, so it reports nothing, which is correct: there is nothing on
/// this machine to lose track of either.
pub fn local_state_resources(lab_infra_dir: &Path) -> Vec<(String, usize)> {
    let Ok(stacks) = std::fs::read_dir(lab_infra_dir) else {
        return Vec::new();
    };

    let mut found = Vec::new();
    for stack in stacks.flatten() {
        let Ok(entries) = std::fs::read_dir(stack.path()) else {
            continue;
        };
        let count: usize = entries
            .flatten()
            .filter(|e| e.path().extension().is_some_and(|x| x == "tfstate"))
            .filter_map(|e| std::fs::read(e.path()).ok())
            .filter_map(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
            .map(|state| {
                state
                    .get("resources")
                    .and_then(serde_json::Value::as_array)
                    .map_or(0, Vec::len)
            })
            .sum();

        if count > 0 {
            found.push((stack.file_name().to_string_lossy().into_owned(), count));
        }
    }
    found.sort();
    found
}

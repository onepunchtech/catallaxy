//! Remove what a lab left on this machine, without needing the flake.
//!
//! `lab destroy` is how a lab is taken down: it runs the lab's teardown plan,
//! releases cloud resources and honours its rescue hints. It needs the flake,
//! because that is where the plan lives.
//!
//! This is the fallback for when the flake cannot answer — the lab was deleted
//! from it, renamed, built from another checkout, or `lab up` died partway. It
//! works from local evidence alone and never evaluates anything.

use anyhow::{Result, bail};
use console::style;

use crate::domain::inventory::{
    CleanupAction, CleanupPlan, Inventory, Orphan, RunningLab, plan_cleanup,
};
use crate::io;

pub struct CleanupRequest {
    pub lab: Option<String>,
    pub all: bool,
    pub orphans: bool,
    pub dry_run: bool,
    pub yes: bool,
    pub keep_state: bool,
}

pub fn run(req: CleanupRequest) -> Result<()> {
    let inventory = crate::domain::inventory::correlate(&io::host_inventory::gather());

    if !inventory.docker_reachable {
        bail!(
            "the docker daemon is not reachable, so nothing can be found or removed. \
             Start docker (or check DOCKER_HOST) and try again."
        );
    }

    let selected = select(&inventory, &req)?;
    let plans: Vec<CleanupPlan> = selected
        .iter()
        .map(|lab| {
            plan_cleanup(
                lab,
                crate::host::state::read_lab_record(&lab.name).as_ref(),
                req.keep_state,
            )
        })
        .collect();

    let orphan_actions = if req.orphans || req.all {
        orphan_plan(&inventory)
    } else {
        Vec::new()
    };

    if plans.iter().all(|p| p.actions.is_empty()) && orphan_actions.is_empty() {
        println!("{} Nothing to clean up", style(">>>").green());
        return Ok(());
    }

    print_plan(&plans, &orphan_actions);

    println!();
    warn_about_provisioned(&selected, req.yes)?;

    if req.dry_run {
        println!();
        println!("{} --dry-run, so nothing was removed", style(">>>").green());
        return Ok(());
    }

    if !req.yes && !confirm()? {
        println!("{} Nothing was removed", style(">>>").yellow());
        return Ok(());
    }

    let mut failed = Vec::new();
    for plan in &plans {
        for action in &plan.actions {
            apply(action, &mut failed);
        }
    }
    for action in &orphan_actions {
        apply(action, &mut failed);
    }

    println!();
    if failed.is_empty() {
        println!("{} Cleaned up", style(">>>").green());
        return Ok(());
    }

    bail!(
        "these could not be removed and are still here:\n  {}",
        failed.join("\n  "),
    )
}

fn select(inventory: &Inventory, req: &CleanupRequest) -> Result<Vec<RunningLab>> {
    if req.all {
        return Ok(inventory.labs.clone());
    }
    if let Some(name) = &req.lab {
        if let Some(lab) = inventory.labs.iter().find(|l| &l.name == name) {
            return Ok(vec![lab.clone()]);
        }
        // Naming a lab is a claim on it, which scanning is not. A network
        // alone never invents a lab in the inventory, deliberately, because
        // the name might be someone else's. Asked for by name it is not a
        // guess, and a lab whose containers are gone but whose network is not
        // is exactly what a half-finished run leaves: the next `lab up`
        // refuses on a subnet that overlaps a network nothing will remove.
        let leftovers = remnants_of(name);
        if leftovers.network.is_some() || leftovers.has_record {
            return Ok(vec![leftovers]);
        }
        bail!(
            "nothing named '{name}' is running on this machine. \
             `cata lab list` shows what is."
        );
    }
    if req.orphans {
        return Ok(Vec::new());
    }
    bail!(
        "name a lab, or pass --all for every lab found here, or --orphans for \
         leftovers no lab claims. `cata lab list` shows what is running."
    )
}

/// What is left of a lab that the inventory no longer recognises.
fn remnants_of(name: &str) -> RunningLab {
    RunningLab {
        name: name.to_string(),
        origin: crate::domain::inventory::Origin::Unknown,
        containers: Vec::new(),
        k3d_clusters: Vec::new(),
        network: io::docker::network_exists(name).then(|| name.to_string()),
        has_record: crate::host::state::read_lab_record(name).is_some(),
        attributions: Default::default(),
    }
}

fn orphan_plan(inventory: &Inventory) -> Vec<CleanupAction> {
    inventory
        .orphans
        .iter()
        .map(|orphan| match orphan {
            Orphan::UnattributedContainer { name, .. } => {
                CleanupAction::RemoveContainer(name.clone())
            }
            Orphan::UnknownK3dCluster { name } => CleanupAction::DestroyK3dCluster(name.clone()),
            Orphan::StaleRecordOnly { lab } => CleanupAction::ForgetState(lab.clone()),
        })
        .collect()
}

/// Say what a lab provisioned that this command will not remove.
///
/// Cleanup takes containers, networks and the lab's state directory. What a
/// stack created lives in a cloud account, and the only record of it is the
/// stack's state, which is deliberately kept outside the lab's state directory
/// so this command cannot delete it. Losing the record would not delete the
/// resources, it would just make them nobody's.
fn warn_about_provisioned(selected: &[RunningLab], yes: bool) -> Result<()> {
    let home = crate::io::fs::home_or_tmp();
    let mut standing = Vec::new();

    for lab in selected {
        let dir = std::path::PathBuf::from(&home)
            .join(crate::host::state::INFRA_DIR)
            .join(&lab.name);
        for (stack, count) in crate::io::tofu::local_state_resources(&dir) {
            standing.push((lab.name.clone(), stack, count));
        }
    }

    if standing.is_empty() {
        println!(
            "{} Cloud resources are not touched. Releasing those is part of the lab's \
             teardown plan, which lives in the flake; use `cata lab destroy` where it can.",
            style("note:").yellow(),
        );
        return Ok(());
    }

    println!(
        "{} these stacks still hold resources:",
        style("note:").yellow()
    );
    for (lab, stack, count) in &standing {
        println!("      {lab} / {stack}: {count} resource(s)");
    }
    println!();
    println!(
        "      Cleaning up removes this machine's containers and networks. It \n      \
         does not release what a stack created, and the state recording it \n      \
         stays where it is, so nothing is lost track of by doing this.\n\n      \
         To release them, run `cata lab destroy <lab> --infra` while the lab \n      \
         is still in a flake that can be evaluated."
    );

    if !yes {
        println!();
        bail!(
            "refusing to clean up while a stack still holds resources. \
             Run `cata lab destroy --infra` first, or pass `--yes` to clean up \
             the local side anyway."
        );
    }
    Ok(())
}

fn describe(action: &CleanupAction) -> String {
    match action {
        CleanupAction::DestroyK3dCluster(name) => format!("destroy k3d cluster {name}"),
        CleanupAction::RemoveContainer(name) => format!("remove container {name}"),
        CleanupAction::RemoveNetwork(name) => format!("remove docker network {name}"),
        CleanupAction::CleanKubeconfig(cluster) => {
            format!("remove kubeconfig entries for {cluster}")
        }
        CleanupAction::ReportOnly { what, .. } => format!("leave {what} alone"),
        CleanupAction::ForgetState(lab) => {
            format!("remove the state directory for {lab}, including its CA")
        }
    }
}

fn print_plan(plans: &[CleanupPlan], orphan_actions: &[CleanupAction]) {
    for plan in plans {
        let Some(lab) = &plan.lab else { continue };
        if plan.actions.is_empty() {
            continue;
        }
        println!();
        println!("{} {}", style("Lab").bold(), style(lab).green());
        for action in &plan.actions {
            println!("  {}", describe(action));
            if let CleanupAction::ReportOnly { remedy, .. } = action {
                println!("      {}", style(remedy).dim());
            }
        }
    }

    if !orphan_actions.is_empty() {
        println!();
        println!("{}", style("Claimed by no lab").bold());
        for action in orphan_actions {
            println!("  {}", describe(action));
        }
    }
}

fn confirm() -> Result<bool> {
    use std::io::Write;
    print!("\nRemove these? [y/N] ");
    std::io::stdout().flush().ok();
    Ok(io::fs::read_line()?.trim().eq_ignore_ascii_case("y"))
}

fn apply(action: &CleanupAction, failed: &mut Vec<String>) {
    match action {
        CleanupAction::DestroyK3dCluster(name) => {
            println!("{} destroying k3d cluster {name}", style(">>>").cyan());
            if io::k3d::cluster_destroy(name, None).is_err() {
                failed.push(format!("k3d cluster {name}"));
                return;
            }
            if !io::k3d::sweep_stragglers(name) {
                failed.push(format!("containers of k3d cluster {name}"));
            }
        }
        CleanupAction::RemoveContainer(name) => {
            println!("{} removing container {name}", style(">>>").cyan());
            io::docker::force_remove_container(name);
            if io::docker::container_exists(name) {
                failed.push(format!("container {name}"));
            }
        }
        CleanupAction::RemoveNetwork(name) => {
            println!("{} removing docker network {name}", style(">>>").cyan());
            io::docker::remove_network(name);
            if io::docker::network_exists(name) {
                failed.push(format!(
                    "docker network {name} is still in use, so something on it did not go"
                ));
            }
        }
        CleanupAction::CleanKubeconfig(cluster) => {
            if let Err(e) = io::kubectl::cleanup_kubeconfig(cluster) {
                failed.push(format!("kubeconfig entries for {cluster}: {e}"));
            }
        }
        CleanupAction::ReportOnly { .. } => {}
        CleanupAction::ForgetState(lab) => {
            if crate::host::state::forget_lab_state(lab).is_err() {
                let dir = crate::host::state::lab_state_dir(lab);
                println!(
                    "{} {} could not be removed. The registry writes its cache as \n      \
                     another uid, so part of it is not yours to delete. Nothing there \n      \
                     holds a port or a name, so the lab is gone either way:\n      \
                     sudo rm -rf {}",
                    style("note:").yellow(),
                    dir.display(),
                    dir.display(),
                );
            }
        }
    }
}

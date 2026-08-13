use anyhow::{Result, bail};
use console::style;

use crate::config::Context as CataContext;
use crate::domain::LabSpec;
use crate::domain::plan::{Direction, PlannedStep, StepParams};
use crate::io;

use super::StepContext;
use super::steps;

pub async fn execute(
    ctx: &CataContext,
    lab_name: &str,
    dry_run: bool,
    direction: Direction,
    up_to: Option<&str>,
) -> Result<()> {
    let mut ctx_owned = ctx.clone();
    if ctx_owned.flake_ref.fragment.is_none() {
        ctx_owned.flake_ref.fragment = Some(lab_name.to_string());
    }
    let ctx = &ctx_owned;

    let lab = crate::io::nix::get_lab_spec(ctx, lab_name)?;
    let steps = load_steps(&lab, direction)?;
    if steps.is_empty() {
        println!(
            "{} No {} steps for lab '{lab_name}'",
            style(">>>").yellow(),
            direction.label(),
        );
        return Ok(());
    }

    let action = match direction {
        Direction::Deploy => "Deploying",
        Direction::Teardown => "Destroying",
    };
    println!(
        "{} {} lab '{lab_name}' ({} steps)",
        style("catallaxy").cyan().bold(),
        action,
        steps.len(),
    );

    let secrets_cache = load_stores_upfront(ctx, lab_name, &lab)?;
    let lab_package = build_lab_package_for(ctx, lab_name, direction)?;

    let step_ctx = StepContext {
        ctx,
        lab_name,
        lab: &lab,
        lab_package: &lab_package,
        secrets_cache,
        strategy: lab.cd.strategy,
        bootstrap: lab.cd.bootstrap,
        dry_run,
        failures: std::cell::RefCell::new(Vec::new()),
    };

    let stop_after = resolve_stop_after(&steps, up_to, direction)?;

    let total = steps.len();
    for (i, step) in steps.iter().enumerate() {
        run_one(&step_ctx, i, total, step).await?;
        if let Some(idx) = stop_after
            && i == idx
        {
            println!();
            println!(
                "{} Stopped at --up-to={} (step {}/{})",
                style(">>>").green(),
                up_to.unwrap(),
                i + 1,
                total,
            );
            return Ok(());
        }
    }

    let failures = step_ctx.failures.into_inner();
    if direction == Direction::Teardown && !failures.is_empty() {
        println!();
        println!(
            "{} Teardown finished with {} non-fatal failure(s):",
            style("Warning:").yellow(),
            failures.len()
        );
        for f in &failures {
            println!("  - {}", f);
        }
    }

    Ok(())
}

async fn run_one(
    sctx: &StepContext<'_>,
    index: usize,
    total: usize,
    step: &PlannedStep,
) -> Result<()> {
    println!();
    println!(
        "{} Step {}/{}: {}",
        style(">>>").cyan(),
        index + 1,
        total,
        style(step.label()).bold(),
    );

    if !sctx.dry_run && should_skip_if_reachable(step) {
        return Ok(());
    }

    if sctx.dry_run && !step.dry_run_safe() {
        println!(
            "{} would run {}",
            style("dry-run").dim(),
            style(step.type_tag()).dim(),
        );
        return Ok(());
    }

    let attempts: u32 = if sctx.dry_run { 1 } else { step.attempts() };

    let mut last_err: Option<anyhow::Error> = None;
    for attempt in 1..=attempts {
        if attempt > 1 {
            let backoff_secs = 2u64.pow(attempt - 2);
            eprintln!(
                "{} attempt {}/{} after {}s (last error: {})",
                style(">>>").yellow(),
                attempt,
                attempts,
                backoff_secs,
                last_err.as_ref().map(|e| e.to_string()).unwrap_or_default(),
            );
            tokio::time::sleep(std::time::Duration::from_secs(backoff_secs)).await;
        }

        match dispatch(sctx, step).await {
            Ok(()) => return Ok(()),
            Err(e) => last_err = Some(e),
        }
    }
    Err(last_err.expect("attempts >= 1 always sets last_err on failure"))
}

async fn dispatch(sctx: &StepContext<'_>, step: &PlannedStep) -> Result<()> {
    match &step.params {
        StepParams::SetupServices(_) => steps::setup_services::run(sctx).await,
        StepParams::DockerNetworkCreate(p) => steps::docker_network_create::run(sctx, p).await,
        StepParams::CertGenerate(p) => steps::cert_generate::run(sctx, p).await,
        StepParams::TrustBundle(_) => steps::trust_bundle::run(sctx),
        StepParams::HostTrustInstall(_) => steps::host_trust_install::run(sctx).await,
        StepParams::DnsSetup(p) => steps::dns_setup::run(sctx, p).await,
        StepParams::DnsTeardown(p) => steps::dns_teardown::run(sctx, p).await,
        StepParams::ColimaNetworkRoute(p) => steps::colima_network_route::run(sctx, p).await,
        StepParams::RegistrySetup(p) => steps::registry_setup::run(sctx, p).await,
        StepParams::WarmCache(_) => steps::warm_cache::run(sctx).await,
        StepParams::CreateCluster(p) => steps::create_cluster::run(sctx, p).await,
        StepParams::EnsureSecrets(p) => steps::ensure_secrets::run(sctx, p),
        StepParams::DeployManifests(p) => steps::deploy_manifests::run(sctx, p).await,
        StepParams::CrossClusterSecretCopy(p) => {
            steps::cross_cluster_secret_copy::run(sctx, p).await
        }
        StepParams::WaitForResources(p) => steps::wait_for_resources::run(sctx, p).await,
        StepParams::SyncKubeconfig(p) => steps::sync_kubeconfig::run(sctx, p),
        StepParams::Pivot(p) => steps::pivot::run(sctx, p).await,
        StepParams::PublishImages(p) => steps::publish_images::run(sctx, p),
        StepParams::PublishManifests(_) => steps::publish_manifests::run(sctx).await,
        StepParams::ApplyRootApplication(p) => steps::apply_root_application::run(sctx, p),
        StepParams::BootstrapForgejoRepos(p) => steps::bootstrap_forgejo_repos::run(sctx, p).await,
        StepParams::BootstrapArgocdKubectlSsa(p) => {
            steps::bootstrap_argocd_kubectl_ssa::run(sctx, p)
        }
        StepParams::BootstrapArgocdHelm(p) => steps::bootstrap_argocd_helm::run(sctx, p),
        StepParams::VerifyArgocdReachable(p) => steps::verify_argocd_reachable::run(sctx, p),
        StepParams::RunScript(p) => steps::run_script::run(sctx, step, p),
        StepParams::DestroyCluster(p) => steps::destroy_cluster::run(sctx, p).await,
        StepParams::ReconcileManagedResource(p) => steps::reconcile_managed_resource::run(sctx, p),
        StepParams::DeleteManagedResource(p) => steps::delete_managed_resource::run(sctx, p),
        StepParams::WaitForClusterGone(p) => steps::wait_for_cluster_gone::run(sctx, p),
        StepParams::ReleaseClusterCloudResources(p) => {
            steps::release_cluster_cloud_resources::run(sctx, p)
        }
        StepParams::RemoveNetwork(_) => steps::remove_network::run(sctx).await,
        StepParams::RemoveServices(_) => steps::remove_services::run(sctx),
    }
}

fn should_skip_if_reachable(step: &PlannedStep) -> bool {
    let Some(skip_ctx) = step.policy.skip_if_cluster_reachable.as_deref() else {
        return false;
    };
    if io::kubectl::api_reachable(skip_ctx) {
        println!(
            "{} Skipping: '{}' is already reachable, no bootstrap needed",
            style(">>>").green(),
            skip_ctx,
        );
        true
    } else {
        false
    }
}

fn load_steps(lab: &LabSpec, direction: Direction) -> Result<Vec<PlannedStep>> {
    let steps = match direction {
        Direction::Deploy => &lab.deployment_plan,
        Direction::Teardown => &lab.teardown_plan,
    };
    for (i, step) in steps.iter().enumerate() {
        step.refuse_wrong_direction(direction, i)?;
    }
    Ok(steps.clone())
}

fn load_stores_upfront(
    ctx: &CataContext,
    lab_name: &str,
    lab: &LabSpec,
) -> Result<Option<crate::domain::SecretsCache>> {
    crate::io::secrets::load_secrets_cache(
        ctx,
        lab_name,
        &lab.secrets,
        "Loading secret stores now so you're not interrupted later...",
    )
}

fn build_lab_package_for(
    ctx: &CataContext,
    lab_name: &str,
    direction: Direction,
) -> Result<String> {
    if direction == Direction::Deploy {
        println!();
        println!("{} Building lab manifests...", style(">>>").cyan());
        let pkg = crate::io::nix::build_lab_package(ctx, lab_name)?;
        println!("{} Lab package built", style(">>>").green());
        Ok(pkg)
    } else {
        println!();
        println!(
            "{} Realizing teardown hook binaries...",
            style(">>>").cyan()
        );
        match crate::io::nix::build_lab_package(ctx, lab_name) {
            Ok(pkg) => {
                println!("{} Lab package built", style(">>>").green());
                Ok(pkg)
            }
            Err(e) => {
                println!(
                    "{} Could not build the lab package: {e}\n    \
                     Teardown hooks and external-name discovery will be skipped \
                     if their binaries are not already in the store; cloud \
                     resources may leak.",
                    style("Warning:").yellow(),
                );
                Ok(String::new())
            }
        }
    }
}

fn resolve_stop_after(
    steps: &[PlannedStep],
    up_to: Option<&str>,
    direction: Direction,
) -> Result<Option<usize>> {
    Ok(match up_to {
        Some(kind) => {
            let idx = steps.iter().rposition(|s| s.type_tag() == kind);
            if idx.is_none() {
                let known = crate::domain::step_kind::StepKind::from_tag(kind).is_some();
                if known {
                    bail!(
                        "--up-to='{}' is a valid kind but the {} plan contains no such step",
                        kind,
                        direction.label(),
                    );
                }
                let mut valid: Vec<&str> = crate::domain::step_kind::StepKind::ALL
                    .iter()
                    .map(|k| k.tag())
                    .collect();
                valid.sort_unstable();
                bail!(
                    "--up-to='{}' is not a step kind. Valid kinds:\n  {}",
                    kind,
                    valid.join("\n  "),
                );
            }
            idx
        }
        None => None,
    })
}

#[cfg(test)]
mod tests {
    use crate::domain::Direction;
    use crate::domain::step_kind::StepKind;

    fn kind(tag: &str) -> StepKind {
        StepKind::from_tag(tag).expect("tag is a known kind")
    }

    #[test]
    fn kinds_that_change_the_world_are_not_dry_run_safe() {
        for tag in [
            "create-cluster",
            "run-script",
            "setup-services",
            "destroy-cluster",
            "remove-network",
            "deploy-manifests",
            "publish-manifests",
            "pivot",
        ] {
            assert!(
                !kind(tag).dry_run_safe(),
                "`{tag}` mutates the world and must be skipped under --dry-run"
            );
        }
    }

    #[test]
    fn read_only_kinds_still_run_under_dry_run() {
        for tag in [
            "wait-for-resources",
            "wait-for-cluster-gone",
            "verify-argocd-reachable",
        ] {
            assert!(
                kind(tag).dry_run_safe(),
                "`{tag}` only observes, so a dry run may execute it"
            );
        }
    }

    #[test]
    fn a_teardown_only_kind_is_refused_in_the_deploy_plan() {
        assert!(!kind("remove-network").runs_in(Direction::Deploy));
        assert!(kind("remove-network").runs_in(Direction::Teardown));
    }

    #[test]
    fn a_deploy_only_kind_is_refused_in_the_teardown_plan() {
        assert!(kind("create-cluster").runs_in(Direction::Deploy));
        assert!(!kind("create-cluster").runs_in(Direction::Teardown));
    }

    #[test]
    fn bidirectional_kinds_run_in_both() {
        for tag in ["run-script", "destroy-cluster"] {
            assert!(
                kind(tag).runs_in(Direction::Deploy) && kind(tag).runs_in(Direction::Teardown),
                "{tag}"
            );
        }
    }
}

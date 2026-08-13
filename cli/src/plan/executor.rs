use anyhow::{Result, bail};
use console::style;

use crate::config::Context as CataContext;
use crate::domain::LabSpec;
use crate::domain::plan::{PlannedStep, StepParams};
use crate::io;

use super::StepContext;
use super::steps;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Deploy,
    Teardown,
}

impl Direction {
    fn label(self) -> &'static str {
        match self {
            Direction::Deploy => "deployment",
            Direction::Teardown => "teardown",
        }
    }
}

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

    if direction == Direction::Teardown && !dry_run {
        crate::commands::lab::orchestrate::reconcile_crossplane_state_for_teardown(&steps);
    }

    let stop_after = resolve_stop_after(&steps, up_to, direction)?;

    let total = steps.len();
    for (i, step) in steps.iter().enumerate() {
        run_one(&step_ctx, i, total, step, direction).await?;
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
    direction: Direction,
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

        match dispatch(sctx, step, direction).await {
            Ok(()) => return Ok(()),
            Err(e) => last_err = Some(e),
        }
    }
    Err(last_err.expect("attempts >= 1 always sets last_err on failure"))
}

async fn dispatch(sctx: &StepContext<'_>, step: &PlannedStep, direction: Direction) -> Result<()> {
    if let Some(result) = dispatch_deploy(sctx, step, direction).await {
        return result;
    }
    if let Some(result) = dispatch_teardown(sctx, step, direction).await {
        return result;
    }
    bail!(
        "step '{}' is not valid in {} direction",
        step.type_tag(),
        direction.label(),
    );
}

async fn dispatch_deploy(
    sctx: &StepContext<'_>,
    step: &PlannedStep,
    direction: Direction,
) -> Option<Result<()>> {
    if let Some(result) = dispatch_host(sctx, step, direction).await {
        return Some(result);
    }
    if let Some(result) = dispatch_cluster(sctx, step, direction).await {
        return Some(result);
    }
    dispatch_gitops(sctx, step, direction).await
}

async fn dispatch_host(
    sctx: &StepContext<'_>,
    step: &PlannedStep,
    direction: Direction,
) -> Option<Result<()>> {
    Some(match (direction, &step.params) {
        (
            Direction::Deploy,
            StepParams::DockerNetworkCreate {
                name,
                subnet,
                gateway,
                ..
            },
        ) => steps::docker_network_create::run(sctx, name, subnet, gateway).await,
        (Direction::Deploy, StepParams::CertGenerate { zone, .. }) => {
            steps::cert_generate::run(sctx, zone).await
        }
        (Direction::Deploy, StepParams::TrustBundle { .. }) => steps::trust_bundle::run(sctx),
        (Direction::Deploy, StepParams::HostTrustInstall { .. }) => {
            steps::host_trust_install::run(sctx).await
        }
        (
            Direction::Deploy,
            StepParams::DnsSetup {
                host, port, zone, ..
            },
        ) => steps::dns_setup::run(sctx, host, *port, zone).await,
        (Direction::Teardown, StepParams::DnsTeardown { zone, .. }) => {
            steps::dns_teardown::run(sctx, zone).await
        }
        (
            Direction::Deploy,
            StepParams::ColimaNetworkRoute {
                subnet, profile, ..
            },
        ) => steps::colima_network_route::run(sctx, subnet, profile).await,
        (
            Direction::Deploy,
            StepParams::RegistrySetup {
                port,
                upstreams,
                zone,
                ..
            },
        ) => steps::registry_setup::run(sctx, *port, upstreams, zone).await,
        (Direction::Deploy, StepParams::SetupServices { .. }) => {
            steps::setup_services::run(sctx).await
        }
        (Direction::Deploy, StepParams::WarmCache { .. }) => steps::warm_cache::run(sctx).await,
        _ => return None,
    })
}

async fn dispatch_cluster(
    sctx: &StepContext<'_>,
    step: &PlannedStep,
    direction: Direction,
) -> Option<Result<()>> {
    if let Some(result) = dispatch_cluster_lifecycle(sctx, step, direction).await {
        return Some(result);
    }
    dispatch_cluster_workloads(sctx, step, direction).await
}

async fn dispatch_cluster_lifecycle(
    sctx: &StepContext<'_>,
    step: &PlannedStep,
    direction: Direction,
) -> Option<Result<()>> {
    Some(match (direction, &step.params) {
        (
            Direction::Deploy,
            StepParams::CreateCluster {
                name, provisioner, ..
            },
        ) => steps::create_cluster::run(sctx, name, provisioner).await,
        (Direction::Deploy, StepParams::EnsureSecrets { stores, .. }) => {
            steps::ensure_secrets::run(sctx, stores)
        }
        (
            Direction::Deploy,
            StepParams::DeployManifests {
                target,
                bootstrap,
                kube_context,
                ..
            },
        ) => steps::deploy_manifests::run(sctx, target, *bootstrap, kube_context.as_deref()).await,
        (
            Direction::Deploy,
            StepParams::CrossClusterSecretCopy {
                source_cluster,
                source_namespace,
                source_secret,
                target_cluster,
                target_namespace,
                target_secret,
                secret_type,
                source_context,
                target_context,
                ..
            },
        ) => {
            steps::cross_cluster_secret_copy::run(
                sctx,
                steps::cross_cluster_secret_copy::SecretCopy {
                    src_cluster: source_cluster,
                    src_namespace: source_namespace,
                    src_secret: source_secret,
                    tgt_cluster: target_cluster,
                    tgt_namespace: target_namespace,
                    tgt_secret: target_secret,
                    override_type: secret_type.as_deref(),
                    source_context: source_context.as_deref(),
                    target_context: target_context.as_deref(),
                },
            )
            .await
        }
        _ => return None,
    })
}

async fn dispatch_cluster_workloads(
    sctx: &StepContext<'_>,
    step: &PlannedStep,
    direction: Direction,
) -> Option<Result<()>> {
    Some(match (direction, &step.params) {
        (
            Direction::Deploy,
            StepParams::PublishImages {
                source_cluster,
                images,
                ..
            },
        ) => steps::publish_images::run(sctx, source_cluster, images),
        (
            Direction::Deploy,
            StepParams::WaitForResources {
                target,
                resources,
                wait_timeout_seconds,
                kube_context,
                ..
            },
        ) => {
            steps::wait_for_resources::run(
                sctx,
                target,
                resources,
                *wait_timeout_seconds,
                kube_context.as_deref(),
            )
            .await
        }
        (
            Direction::Deploy,
            StepParams::SyncKubeconfig {
                target,
                clusters,
                kube_context,
                ..
            },
        ) => steps::sync_kubeconfig::run(sctx, target, clusters, kube_context.as_deref()),
        (
            Direction::Deploy,
            StepParams::Pivot {
                cluster,
                bootstrap_context,
                target_context,
                provisioner,
                ..
            },
        ) => {
            steps::pivot::run(
                sctx,
                cluster,
                bootstrap_context,
                target_context,
                provisioner,
            )
            .await
        }
        (
            Direction::Deploy,
            StepParams::DestroyCluster {
                name,
                provisioner,
                skip_if_missing,
                ..
            },
        ) => {
            steps::destroy_cluster::run(sctx, name, provisioner, skip_if_missing.unwrap_or(false))
                .await
        }
        _ => return None,
    })
}

async fn dispatch_gitops(
    sctx: &StepContext<'_>,
    step: &PlannedStep,
    direction: Direction,
) -> Option<Result<()>> {
    if let Some(result) = dispatch_gitops_repo(sctx, step, direction).await {
        return Some(result);
    }
    dispatch_gitops_argocd(sctx, step, direction).await
}

async fn dispatch_gitops_repo(
    sctx: &StepContext<'_>,
    step: &PlannedStep,
    direction: Direction,
) -> Option<Result<()>> {
    Some(match (direction, &step.params) {
        (
            Direction::Deploy,
            StepParams::BootstrapForgejoRepos {
                target,
                namespace,
                job_label_selector,
                kube_context,
                ..
            },
        ) => {
            steps::bootstrap_forgejo_repos::run(
                sctx,
                target,
                namespace.as_deref(),
                job_label_selector.as_deref(),
                kube_context.as_deref(),
            )
            .await
        }
        (Direction::Deploy, StepParams::PublishManifests { .. }) => {
            steps::publish_manifests::run(sctx).await
        }
        _ => return None,
    })
}

async fn dispatch_gitops_argocd(
    sctx: &StepContext<'_>,
    step: &PlannedStep,
    direction: Direction,
) -> Option<Result<()>> {
    Some(match (direction, &step.params) {
        (
            Direction::Deploy,
            StepParams::ApplyRootApplication {
                target,
                namespace,
                manifest_path,
                kube_context,
                ..
            },
        ) => steps::apply_root_application::run(
            sctx,
            target,
            namespace.as_deref(),
            manifest_path.as_deref(),
            kube_context.as_deref(),
        ),
        (
            Direction::Deploy,
            StepParams::BootstrapArgocdKubectlSsa {
                target,
                kube_context,
                manifest_root,
                field_manager,
                namespace,
                wait_timeout_seconds,
                ..
            },
        ) => steps::bootstrap_argocd_kubectl_ssa::run(
            sctx,
            target,
            kube_context.as_deref(),
            manifest_root,
            field_manager.as_deref(),
            namespace.as_deref(),
            *wait_timeout_seconds,
        ),
        (
            Direction::Deploy,
            StepParams::BootstrapArgocdHelm {
                target,
                kube_context,
                values_path,
                chart_ref,
                release_name,
                namespace,
                ..
            },
        ) => steps::bootstrap_argocd_helm::run(
            sctx,
            steps::bootstrap_argocd_helm::ArgocdHelm {
                target,
                kube_context: kube_context.as_deref(),
                values_path,
                chart_ref,
                release_name,
                namespace: namespace.as_deref(),
            },
        ),
        (
            Direction::Deploy,
            StepParams::VerifyArgocdReachable {
                target,
                kube_context,
                namespace,
                ..
            },
        ) => steps::verify_argocd_reachable::run(
            sctx,
            target,
            kube_context.as_deref(),
            namespace.as_deref(),
        ),
        (
            Direction::Deploy | Direction::Teardown,
            StepParams::RunScript {
                bin,
                env,
                kube_context,
                ..
            },
        ) => steps::run_script::run(
            sctx,
            bin,
            Some(step.name.as_str()),
            env,
            kube_context.as_deref(),
            step.continues_on_failure(),
        ),

        _ => return None,
    })
}

async fn dispatch_teardown(
    sctx: &StepContext<'_>,
    step: &PlannedStep,
    direction: Direction,
) -> Option<Result<()>> {
    Some(match (direction, &step.params) {
        (
            Direction::Teardown,
            StepParams::ReleaseClusterCloudResources {
                target,
                kube_context,
                wait_timeout_seconds,
                ..
            },
        ) => steps::release_cluster_cloud_resources::run(
            sctx,
            target,
            kube_context.as_deref(),
            wait_timeout_seconds.unwrap_or(600),
        ),
        (
            Direction::Teardown,
            StepParams::DeleteManagedResource {
                target,
                resource_kind,
                resource_name,
                wait,
                wait_timeout_seconds,
                kube_context,
                ..
            },
        ) => steps::delete_managed_resource::run(
            sctx,
            target,
            resource_kind,
            resource_name,
            wait.unwrap_or(true),
            wait_timeout_seconds.unwrap_or(1200),
            kube_context.as_deref(),
        ),
        (
            Direction::Teardown,
            StepParams::WaitForClusterGone {
                target,
                kube_context,
                resource_kind,
                resource_name,
                wait_timeout_seconds,
                ..
            },
        ) => steps::wait_for_cluster_gone::run(
            sctx,
            target.as_deref(),
            kube_context.as_deref(),
            resource_kind.as_deref(),
            resource_name.as_deref(),
            wait_timeout_seconds.unwrap_or(600),
        ),
        (
            Direction::Teardown,
            StepParams::DestroyCluster {
                name,
                provisioner,
                skip_if_missing,
                ..
            },
        ) => {
            steps::destroy_cluster::run(sctx, name, provisioner, skip_if_missing.unwrap_or(false))
                .await
        }
        (Direction::Teardown, StepParams::RemoveServices { .. }) => {
            steps::remove_services::run(sctx)
        }
        (Direction::Teardown, StepParams::RemoveNetwork { .. }) => {
            steps::remove_network::run(sctx).await
        }

        _ => return None,
    })
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
        if !step.runs_in(direction.label()) {
            bail!(
                "{} plan step {} is '{}', which the executor only runs in the \
                 other direction. Refusing to start: aborting part-way through \
                 would leave the lab half-built.",
                direction.label(),
                i + 1,
                step.type_tag(),
            );
        }
    }
    Ok(steps.clone())
}

fn load_stores_upfront(
    ctx: &CataContext,
    lab_name: &str,
    lab: &LabSpec,
) -> Result<Option<crate::commands::apply::SecretsCache>> {
    crate::commands::secrets::load_secrets_cache(
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
        assert!(!kind("remove-network").runs_in("deployment"));
        assert!(kind("remove-network").runs_in("teardown"));
    }

    #[test]
    fn a_deploy_only_kind_is_refused_in_the_teardown_plan() {
        assert!(kind("create-cluster").runs_in("deployment"));
        assert!(!kind("create-cluster").runs_in("teardown"));
    }

    #[test]
    fn bidirectional_kinds_run_in_both() {
        for tag in ["run-script", "destroy-cluster"] {
            assert!(
                kind(tag).runs_in("deployment") && kind(tag).runs_in("teardown"),
                "{tag}"
            );
        }
    }
}

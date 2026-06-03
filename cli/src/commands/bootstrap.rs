//! Bootstrap command for CAPI-based cluster initialization
//!
//! Implements the Day 0 bootstrap sequence:
//! 1. Create k3d cluster as bootstrap environment
//! 2. Initialize CAPI on k3d
//! 3. Apply CAPI cluster manifests
//! 4. Wait for workload cluster to be ready
//! 5. Pivot CAPI resources to workload cluster
//! 6. Bootstrap components (Cilium, cert-manager, ArgoCD, etc.)
//! 7. Delete k3d cluster

use std::fs;
use std::path::PathBuf;

use anyhow::{Result, bail};
use clap::{Args, Subcommand};
use console::style;

use crate::config::Context as CataContext;
use crate::nix;
use crate::tools::{self, clusterctl, k3d};

const BOOTSTRAP_CLUSTER_NAME: &str = "capi-bootstrap";
const BOOTSTRAP_STATE_FILE: &str = ".cata-bootstrap-state.json";

#[derive(Args)]
pub struct BootstrapArgs {
    #[command(subcommand)]
    pub command: BootstrapCommands,
}

#[derive(Subcommand)]
pub enum BootstrapCommands {
    /// Initialize a new management cluster via CAPI
    Init {
        /// Cluster name (defaults to flake fragment if provided)
        cluster: Option<String>,

        /// Stop after cluster is ready, don't pivot
        #[arg(long)]
        no_pivot: bool,

        /// Don't delete bootstrap cluster after pivot
        #[arg(long)]
        keep_bootstrap: bool,

        /// Skip component bootstrapping after pivot
        #[arg(long)]
        no_bootstrap: bool,
    },

    /// Resume an interrupted bootstrap process
    Resume {
        /// Cluster name (defaults to flake fragment if provided)
        cluster: Option<String>,
    },

    /// Clean up leftover bootstrap resources
    Cleanup,

    /// Show bootstrap status
    Status,
}

/// Bootstrap state persisted between runs
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
struct BootstrapState {
    cluster_name: String,
    phase: BootstrapPhase,
    bootstrap_cluster_created: bool,
    capi_initialized: bool,
    manifests_applied: bool,
    cluster_ready: bool,
    kubeconfig_saved: bool,
    pivoted: bool,
    bootstrapped: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
enum BootstrapPhase {
    NotStarted,
    BootstrapClusterCreated,
    CapiInitialized,
    ManifestsApplied,
    ClusterReady,
    KubeconfigSaved,
    Pivoted,
    Bootstrapped,
    Complete,
}

impl BootstrapState {
    fn new(cluster_name: &str) -> Self {
        Self {
            cluster_name: cluster_name.to_string(),
            phase: BootstrapPhase::NotStarted,
            bootstrap_cluster_created: false,
            capi_initialized: false,
            manifests_applied: false,
            cluster_ready: false,
            kubeconfig_saved: false,
            pivoted: false,
            bootstrapped: false,
        }
    }

    fn load() -> Option<Self> {
        let path = state_file_path();
        if path.exists() {
            let content = fs::read_to_string(&path).ok()?;
            serde_json::from_str(&content).ok()
        } else {
            None
        }
    }

    fn save(&self) -> Result<()> {
        let path = state_file_path();
        let content = serde_json::to_string_pretty(self)?;
        fs::write(&path, content)?;
        Ok(())
    }

    fn clear() -> Result<()> {
        let path = state_file_path();
        if path.exists() {
            fs::remove_file(&path)?;
        }
        Ok(())
    }
}

fn state_file_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home)
        .join(".cache")
        .join("catallaxy")
        .join(BOOTSTRAP_STATE_FILE)
}

pub async fn run(ctx: &CataContext, args: BootstrapArgs) -> Result<()> {
    match args.command {
        BootstrapCommands::Init {
            cluster,
            no_pivot,
            keep_bootstrap,
            no_bootstrap,
        } => {
            let name = ctx.resolve_cluster_name(cluster.as_deref())?;
            init(ctx, &name, no_pivot, keep_bootstrap, no_bootstrap).await
        }
        BootstrapCommands::Resume { cluster } => {
            let name = ctx.resolve_cluster_name(cluster.as_deref())?;
            resume(ctx, &name).await
        }
        BootstrapCommands::Cleanup => cleanup(ctx).await,
        BootstrapCommands::Status => status().await,
    }
}

async fn init(
    ctx: &CataContext,
    cluster_name: &str,
    no_pivot: bool,
    keep_bootstrap: bool,
    no_bootstrap: bool,
) -> Result<()> {
    println!(
        "{} Bootstrapping management cluster '{cluster_name}'",
        style("catallaxy").cyan().bold()
    );
    println!();

    // Check required tools
    tools::check_tool("k3d")?;
    tools::check_tool("clusterctl")?;
    tools::check_tool("kubectl")?;

    // Load and validate cluster config
    println!("{} Loading cluster configuration...", style(">>>").cyan());
    let config = nix::get_cluster_config(ctx, cluster_name)?;

    // Validate this is a management cluster
    let is_management = config
        .pointer("/components/cluster-api/isManagementCluster")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    if !is_management {
        bail!(
            "Cluster '{cluster_name}' is not marked as a management cluster.\n\
             Set components.cluster-api.isManagementCluster = true in the cluster config."
        );
    }

    let capi_enabled = config
        .pointer("/components/cluster-api/enable")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    if !capi_enabled {
        bail!(
            "Cluster API is not enabled for '{cluster_name}'.\n\
             Set components.cluster-api.enable = true in the cluster config."
        );
    }

    // Initialize state
    let mut state = BootstrapState::new(cluster_name);

    // Ensure state directory exists
    let state_dir = state_file_path().parent().unwrap().to_path_buf();
    fs::create_dir_all(&state_dir)?;

    // Step 1: Create k3d bootstrap cluster
    if !state.bootstrap_cluster_created {
        if k3d::cluster_exists(BOOTSTRAP_CLUSTER_NAME, None) {
            println!(
                "{} Bootstrap k3d cluster already exists",
                style(">>>").yellow()
            );
        } else {
            k3d::cluster_create(
                ctx,
                BOOTSTRAP_CLUSTER_NAME,
                0,     // no workers needed for bootstrap
                true,  // no traefik
                true,  // no servicelb
                false, // keep flannel for simplicity
                None,  // default image
                None,  // no custom docker host
                None,  // no registries.yaml (bootstrap doesn't need caching)
                None,  // default service CIDR
                None,  // default pod CIDR
                &[],   // no auto-deploy manifests
                &[],   // no port mappings
                None,  // no shared network
            )?;
        }
        state.bootstrap_cluster_created = true;
        state.phase = BootstrapPhase::BootstrapClusterCreated;
        state.save()?;
    }

    let bootstrap_context = format!("k3d-{BOOTSTRAP_CLUSTER_NAME}");

    // Step 2: Initialize CAPI on bootstrap cluster
    if !state.capi_initialized {
        let providers = build_provider_spec(&config)?;
        clusterctl::init(ctx, &bootstrap_context, &providers)?;
        state.capi_initialized = true;
        state.phase = BootstrapPhase::CapiInitialized;
        state.save()?;
    }

    // Step 3: Apply CAPI cluster manifests
    if !state.manifests_applied {
        println!("{} Building CAPI manifests...", style(">>>").cyan());
        let manifests_path = nix::build_manifests(ctx, cluster_name)?;

        // Find and apply the CAPI cluster application
        let capi_app_name = format!("capi-cluster-{cluster_name}");
        let capi_app_path = PathBuf::from(&manifests_path).join(&capi_app_name);

        if !capi_app_path.exists() {
            bail!(
                "CAPI cluster manifests not found at {}\n\
                 Ensure components.cluster-api.clusters.{} is defined.",
                capi_app_path.display(),
                cluster_name
            );
        }

        let namespace = config
            .pointer("/components/cluster-api/namespace")
            .and_then(|v| v.as_str())
            .unwrap_or("capi-system");

        // Create namespace if needed
        let _ = std::process::Command::new("kubectl")
            .args([
                "--context",
                &bootstrap_context,
                "create",
                "namespace",
                namespace,
            ])
            .output();

        tools::kapp::deploy(
            ctx,
            &bootstrap_context,
            &capi_app_name,
            &capi_app_path.display().to_string(),
            "15m",
        )?;

        state.manifests_applied = true;
        state.phase = BootstrapPhase::ManifestsApplied;
        state.save()?;
    }

    // Step 4: Wait for cluster to be ready
    let namespace = config
        .pointer("/components/cluster-api/namespace")
        .and_then(|v| v.as_str())
        .unwrap_or("capi-system");

    if !state.cluster_ready {
        // First wait for control plane initialization
        clusterctl::wait_control_plane_initialized(
            ctx,
            &bootstrap_context,
            cluster_name,
            namespace,
            "30m",
        )?;

        // Then wait for full cluster ready
        clusterctl::wait_cluster_ready(ctx, &bootstrap_context, cluster_name, namespace, "30m")?;

        state.cluster_ready = true;
        state.phase = BootstrapPhase::ClusterReady;
        state.save()?;
    }

    // Step 5: Get and save kubeconfig
    let workload_kubeconfig_path =
        PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string()))
            .join(".kube")
            .join(format!("{cluster_name}.kubeconfig"));

    if !state.kubeconfig_saved {
        let kubeconfig =
            clusterctl::get_kubeconfig(ctx, &bootstrap_context, cluster_name, namespace)?;

        // Save kubeconfig
        fs::create_dir_all(workload_kubeconfig_path.parent().unwrap())?;
        fs::write(&workload_kubeconfig_path, &kubeconfig)?;

        println!(
            "{} Kubeconfig saved to {}",
            style(">>>").green(),
            workload_kubeconfig_path.display()
        );

        state.kubeconfig_saved = true;
        state.phase = BootstrapPhase::KubeconfigSaved;
        state.save()?;
    }

    if no_pivot {
        println!();
        println!(
            "{} Bootstrap paused (--no-pivot). Cluster is ready but not pivoted.",
            style("Note:").yellow()
        );
        println!("       Kubeconfig: {}", workload_kubeconfig_path.display());
        println!("       Bootstrap cluster: k3d-{BOOTSTRAP_CLUSTER_NAME}");
        println!();
        println!("       To continue: cata bootstrap resume {cluster_name}");
        println!("       To clean up: cata bootstrap cleanup");
        return Ok(());
    }

    // Step 6: Initialize CAPI on the new management cluster
    let workload_context = format!("{cluster_name}-admin");

    // Merge kubeconfig into default config
    tools::kube::merge_kubeconfig(&workload_kubeconfig_path, &workload_context)?;

    if !state.pivoted {
        // Initialize CAPI on workload cluster before pivot
        let providers = build_provider_spec(&config)?;
        clusterctl::init(ctx, &workload_context, &providers)?;

        // Pivot CAPI resources
        clusterctl::move_resources(ctx, &bootstrap_context, &workload_context, namespace)?;

        state.pivoted = true;
        state.phase = BootstrapPhase::Pivoted;
        state.save()?;
    }

    // Step 7: Bootstrap components
    if !no_bootstrap && !state.bootstrapped {
        println!();
        println!(
            "{} Bootstrapping cluster components...",
            style(">>>").cyan()
        );

        // Run normal apply workflow
        crate::commands::apply::run(
            ctx,
            crate::commands::apply::ApplyArgs {
                cluster: Some(cluster_name.to_string()),
                phase: None,
                component: None,
                dry_run: false,
                force: true, // bootstrap always applies directly
                sequential: false,
                manifests_dir: None,
                secrets_cache: None,
            },
        )
        .await?;

        state.bootstrapped = true;
        state.phase = BootstrapPhase::Bootstrapped;
        state.save()?;
    }

    // Step 8: Clean up bootstrap cluster
    if !keep_bootstrap {
        k3d::cluster_destroy(ctx, BOOTSTRAP_CLUSTER_NAME, None)?;
    } else {
        println!(
            "{} Keeping bootstrap cluster 'k3d-{BOOTSTRAP_CLUSTER_NAME}' (--keep-bootstrap)",
            style("Note:").yellow()
        );
    }

    state.phase = BootstrapPhase::Complete;
    state.save()?;

    // Clear state on success
    BootstrapState::clear()?;

    println!();
    println!(
        "{} Management cluster '{cluster_name}' bootstrapped successfully!",
        style(">>>").green()
    );
    println!();
    println!("  Kubeconfig: {}", workload_kubeconfig_path.display());
    println!("  Context: {workload_context}");
    println!();
    println!("  Next steps:");
    println!("    kubectl --context {workload_context} get nodes");
    println!("    kubectl --context {workload_context} get clusters -A");

    Ok(())
}

async fn resume(ctx: &CataContext, cluster_name: &str) -> Result<()> {
    let state = BootstrapState::load();

    match state {
        Some(state) if state.cluster_name == cluster_name => {
            println!(
                "{} Resuming bootstrap for '{cluster_name}' from phase {:?}",
                style(">>>").cyan(),
                state.phase
            );

            // Continue from where we left off
            init(ctx, cluster_name, false, false, false).await
        }
        Some(state) => {
            bail!(
                "Bootstrap state exists for '{}', not '{cluster_name}'.\n\
                 Run 'cata bootstrap cleanup' first or resume with the correct cluster name.",
                state.cluster_name
            );
        }
        None => {
            bail!(
                "No bootstrap state found.\n\
                 Run 'cata bootstrap init {cluster_name}' to start a new bootstrap."
            );
        }
    }
}

async fn cleanup(ctx: &CataContext) -> Result<()> {
    println!("{} Cleaning up bootstrap resources...", style(">>>").cyan());

    // Delete bootstrap cluster if it exists
    if k3d::cluster_exists(BOOTSTRAP_CLUSTER_NAME, None) {
        k3d::cluster_destroy(ctx, BOOTSTRAP_CLUSTER_NAME, None)?;
    } else {
        println!("{} Bootstrap cluster does not exist", style(">>>").dim());
    }

    // Clear state
    BootstrapState::clear()?;

    println!("{} Bootstrap cleanup complete", style(">>>").green());

    Ok(())
}

async fn status() -> Result<()> {
    println!("{} Bootstrap status", style("catallaxy").cyan().bold());
    println!();

    // Check for existing state
    if let Some(state) = BootstrapState::load() {
        println!("{}", style("Active bootstrap:").bold());
        println!("  Cluster: {}", state.cluster_name);
        println!("  Phase: {:?}", state.phase);
        println!();
        println!("{}", style("Progress:").bold());
        println!(
            "  [{}] Bootstrap cluster created",
            if state.bootstrap_cluster_created {
                "x"
            } else {
                " "
            }
        );
        println!(
            "  [{}] CAPI initialized",
            if state.capi_initialized { "x" } else { " " }
        );
        println!(
            "  [{}] Manifests applied",
            if state.manifests_applied { "x" } else { " " }
        );
        println!(
            "  [{}] Cluster ready",
            if state.cluster_ready { "x" } else { " " }
        );
        println!(
            "  [{}] Kubeconfig saved",
            if state.kubeconfig_saved { "x" } else { " " }
        );
        println!("  [{}] Pivoted", if state.pivoted { "x" } else { " " });
        println!(
            "  [{}] Bootstrapped",
            if state.bootstrapped { "x" } else { " " }
        );
    } else {
        println!("  No active bootstrap in progress.");
    }

    // Check for leftover bootstrap cluster
    println!();
    println!("{}", style("Bootstrap cluster:").bold());
    if k3d::cluster_exists(BOOTSTRAP_CLUSTER_NAME, None) {
        println!("  k3d-{} exists", style(BOOTSTRAP_CLUSTER_NAME).yellow());
        println!("  Run 'cata bootstrap cleanup' to remove.");
    } else {
        println!("  (none)");
    }

    Ok(())
}

/// Build provider spec from cluster config
pub fn build_provider_spec(config: &serde_json::Value) -> Result<clusterctl::ProviderSpec> {
    let bootstrap_providers: Vec<String> = config
        .pointer("/components/cluster-api/bootstrapProviders")
        .and_then(|v| serde_json::from_value(v.clone()).ok())
        .unwrap_or_else(|| vec!["talos".to_string()]);

    let control_plane_providers: Vec<String> = config
        .pointer("/components/cluster-api/controlPlaneProviders")
        .and_then(|v| serde_json::from_value(v.clone()).ok())
        .unwrap_or_else(|| vec!["talos".to_string()]);

    let infra_providers: Vec<String> = config
        .pointer("/components/cluster-api/infrastructureProviders")
        .and_then(|v| serde_json::from_value(v.clone()).ok())
        .unwrap_or_default();

    if infra_providers.is_empty() {
        bail!(
            "No infrastructure providers configured.\n\
             Set components.cluster-api.infrastructureProviders in the cluster config."
        );
    }

    Ok(clusterctl::ProviderSpec {
        bootstrap: bootstrap_providers,
        control_plane: control_plane_providers,
        infrastructure: infra_providers,
    })
}

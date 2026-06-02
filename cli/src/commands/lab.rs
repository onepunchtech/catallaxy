//! Lab management commands — multi-cluster environment lifecycle
//!
//! Labs are defined in the flake's `labs` output, just like clusters
//! are defined in the `clusters` output. Uses the same --flake flag:
//!
//!   cata --flake /path/to/flake#homelab lab up
//!   cata --flake /path/to/flake lab list
//!
//! All clusters are provisioned directly via k3d and manifests are
//! applied to each cluster independently.

use std::fs;
use std::io::Write as IoWrite;
use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use clap::Subcommand;
use console::style;

use crate::commands::kubeconfig;
use crate::config::Context as CataContext;
use crate::lint;
use crate::tools;

#[derive(Subcommand)]
pub enum LabCommands {
    /// List all defined labs
    List,

    /// Show lab status (clusters and services)
    Status {
        /// Lab name (defaults to flake fragment if provided)
        name: Option<String>,
    },

    /// Initialize lab infrastructure and provision all clusters (no apply)
    Init {
        /// Lab name (defaults to flake fragment if provided)
        name: Option<String>,
    },

    /// Initialize lab and apply manifests to all clusters (full bootstrap)
    Up {
        /// Lab name (defaults to flake fragment if provided)
        name: Option<String>,

        /// Apply only a specific phase
        #[arg(long)]
        phase: Option<String>,

        /// Apply only a specific component
        #[arg(long)]
        component: Option<String>,

        /// Dry run (don't actually apply)
        #[arg(long)]
        dry_run: bool,

        /// Force direct apply even when the lab uses a GitOps strategy
        #[arg(long)]
        force: bool,
    },

    /// Stop lab clusters (preserves state, restartable with `lab up`)
    Down {
        /// Lab name (defaults to flake fragment if provided)
        name: Option<String>,
    },

    /// Destroy lab completely (deletes clusters, cloud resources, services, network)
    Destroy {
        /// Lab name (defaults to flake fragment if provided)
        name: Option<String>,
    },

    /// Show the computed deployment plan without executing
    Plan {
        /// Lab name (defaults to flake fragment if provided)
        name: Option<String>,

        /// Show teardown plan instead of deployment plan
        #[arg(long)]
        teardown: bool,
    },

    /// Apply manifests to all lab clusters
    Apply {
        /// Lab name (defaults to flake fragment if provided)
        name: Option<String>,

        /// Apply only a specific phase
        #[arg(long)]
        phase: Option<String>,

        /// Apply only a specific component
        #[arg(long)]
        component: Option<String>,

        /// Dry run (don't actually apply)
        #[arg(long)]
        dry_run: bool,

        /// Force direct apply even when the lab uses a GitOps strategy
        #[arg(long)]
        force: bool,
    },

    /// Lint rendered manifests for correctness
    Lint {
        /// Lab name (builds package via nix, then lints)
        name: Option<String>,
        /// Path to pre-built lab package (skip nix build)
        #[arg(long)]
        path: Option<PathBuf>,
        /// Checks to skip (comma-separated: schema,identity,prefix,selector,reference)
        #[arg(long, value_delimiter = ',')]
        skip: Vec<String>,
    },

    /// Publish rendered manifests to a git repository
    Publish {
        /// Lab name (defaults to flake fragment if provided)
        name: Option<String>,
        /// Create a PR/MR instead of pushing directly
        #[arg(long)]
        pr: bool,
        /// Commit message (auto-generated if not provided)
        #[arg(long)]
        message: Option<String>,
        /// Dry run — show what would be published without pushing
        #[arg(long)]
        dry_run: bool,
    },

    /// Run lab operations tool (component-aware runtime helpers)
    #[command(trailing_var_arg = true)]
    Ops {
        /// Lab name (defaults to flake fragment if provided)
        #[arg(long)]
        name: Option<String>,
        /// Arguments passed to the ops tool
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
    },

    /// Configure local DNS resolution for lab services
    Dns {
        /// Lab name (defaults to flake fragment if provided)
        name: Option<String>,
        /// Auto-configure system resolver (requires sudo)
        #[arg(long)]
        setup: bool,
        /// Remove DNS configuration
        #[arg(long)]
        teardown: bool,
    },

    /// Manage lab TLS CA trust (for HTTPS without browser warnings)
    Trust {
        /// Lab name (defaults to flake fragment if provided)
        name: Option<String>,
        /// Add lab CA to system trust store (requires sudo)
        #[arg(long)]
        setup: bool,
        /// Remove lab CA from system trust store (requires sudo)
        #[arg(long)]
        teardown: bool,
        /// Print CA certificate PEM to stdout
        #[arg(long)]
        export: bool,
    },
}

pub async fn run(ctx: &CataContext, command: LabCommands) -> Result<()> {
    match command {
        LabCommands::List => list(ctx).await,
        LabCommands::Status { name } => {
            let name = ctx.resolve_lab_name(name.as_deref())?;
            status(ctx, &name).await
        }
        LabCommands::Init { name } => {
            let name = ctx.resolve_lab_name(name.as_deref())?;
            init(ctx, &name).await
        }
        LabCommands::Up {
            name,
            phase,
            component,
            dry_run,
            force,
        } => {
            let name = ctx.resolve_lab_name(name.as_deref())?;
            up(ctx, &name, phase, component, dry_run, force).await
        }
        LabCommands::Apply {
            name,
            phase,
            component,
            dry_run,
            force,
        } => {
            let name = ctx.resolve_lab_name(name.as_deref())?;
            apply(ctx, &name, phase, component, dry_run, force).await
        }
        LabCommands::Plan { name, teardown } => {
            let name = ctx.resolve_lab_name(name.as_deref())?;
            plan(ctx, &name, teardown).await
        }
        LabCommands::Down { name } => {
            let name = ctx.resolve_lab_name(name.as_deref())?;
            down(ctx, &name).await
        }
        LabCommands::Destroy { name } => {
            let name = ctx.resolve_lab_name(name.as_deref())?;
            destroy(ctx, &name).await
        }
        LabCommands::Lint { name, path, skip } => lint_cmd(ctx, name, path, skip).await,
        LabCommands::Publish {
            name,
            pr,
            message,
            dry_run,
        } => {
            let name = ctx.resolve_lab_name(name.as_deref())?;
            publish(ctx, &name, pr, message, dry_run).await
        }
        LabCommands::Ops { name, args } => {
            let name = ctx.resolve_lab_name(name.as_deref())?;
            ops(ctx, &name, &args).await
        }
        LabCommands::Dns {
            name,
            setup,
            teardown,
        } => {
            let name = ctx.resolve_lab_name(name.as_deref())?;
            dns(ctx, &name, setup, teardown).await
        }
        LabCommands::Trust {
            name,
            setup,
            teardown,
            export,
        } => {
            let name = ctx.resolve_lab_name(name.as_deref())?;
            trust(ctx, &name, setup, teardown, export).await
        }
    }
}

/// State directory for a lab service's mounted files
fn service_state_dir(lab_name: &str, svc_name: &str) -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home)
        .join(".local/share/catallaxy/labs")
        .join(lab_name)
        .join(svc_name)
}

/// State directory for a lab (parent of service dirs)
fn lab_state_dir(lab_name: &str) -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home)
        .join(".local/share/catallaxy/labs")
        .join(lab_name)
}

/// Generate a self-signed CA and wildcard certificate for the lab ingress
fn ensure_ingress_cert(lab_name: &str, zone: &str) -> Result<PathBuf> {
    use std::process::Command;

    let ingress_dir = service_state_dir(lab_name, "ingress");
    let cert_pem = ingress_dir.join("lab.pem");
    let ca_cert = ingress_dir.join("ca.crt");
    let ca_key = ingress_dir.join("ca.key");

    if cert_pem.exists() {
        return Ok(ingress_dir);
    }

    fs::create_dir_all(&ingress_dir)?;

    println!(
        "{} Generating lab TLS certificate for *.{}...",
        style(">>>").cyan(),
        zone
    );

    // Generate CA key
    let status = Command::new("openssl")
        .args(["genrsa", "-out"])
        .arg(&ca_key)
        .arg("4096")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .context("Failed to run openssl genrsa for CA")?;
    if !status.success() {
        bail!("Failed to generate CA key");
    }

    // Generate CA cert
    let status = Command::new("openssl")
        .args(["req", "-new", "-x509", "-key"])
        .arg(&ca_key)
        .args(["-out"])
        .arg(&ca_cert)
        .args(["-days", "3650", "-subj", "/CN=Catallaxy Lab CA"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .context("Failed to run openssl req for CA")?;
    if !status.success() {
        bail!("Failed to generate CA certificate");
    }

    // Generate server key
    let srv_key = ingress_dir.join("lab.key");
    let status = Command::new("openssl")
        .args(["genrsa", "-out"])
        .arg(&srv_key)
        .arg("4096")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .context("Failed to run openssl genrsa for server")?;
    if !status.success() {
        bail!("Failed to generate server key");
    }

    // Generate CSR with SAN
    let srv_csr = ingress_dir.join("lab.csr");
    let san = format!("subjectAltName=DNS:*.{},DNS:{}", zone, zone);
    let status = Command::new("openssl")
        .args(["req", "-new", "-key"])
        .arg(&srv_key)
        .args(["-out"])
        .arg(&srv_csr)
        .args(["-subj", &format!("/CN=*.{}", zone), "-addext", &san])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .context("Failed to run openssl req for server CSR")?;
    if !status.success() {
        bail!("Failed to generate server CSR");
    }

    // Sign cert with CA
    let srv_crt = ingress_dir.join("lab.crt");
    let status = Command::new("openssl")
        .args(["x509", "-req", "-in"])
        .arg(&srv_csr)
        .args(["-CA"])
        .arg(&ca_cert)
        .args(["-CAkey"])
        .arg(&ca_key)
        .args(["-CAcreateserial", "-out"])
        .arg(&srv_crt)
        .args(["-days", "365", "-copy_extensions", "copyall"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .context("Failed to run openssl x509 for signing")?;
    if !status.success() {
        bail!("Failed to sign server certificate");
    }

    // Combine cert + key into PEM for HAProxy
    let crt_data = fs::read_to_string(&srv_crt)?;
    let key_data = fs::read_to_string(&srv_key)?;
    fs::write(&cert_pem, format!("{}{}", crt_data, key_data))?;

    println!(
        "{} TLS certificate generated at {}",
        style(">>>").green(),
        ingress_dir.display()
    );

    Ok(ingress_dir)
}

/// Generate registries.yaml for k3s/k3d with platform-appropriate host
pub fn generate_registries_yaml(port: u16) -> String {
    // Use platform-appropriate host to reach the registry from inside containers
    let host = if cfg!(target_os = "macos") {
        "host.docker.internal"
    } else {
        // Linux: use docker bridge gateway
        "172.17.0.1"
    };

    format!(
        r#"mirrors:
  docker.io:
    endpoint: ["http://{host}:{port}"]
  quay.io:
    endpoint: ["http://{host}:{port}"]
  ghcr.io:
    endpoint: ["http://{host}:{port}"]
  registry.k8s.io:
    endpoint: ["http://{host}:{port}"]
"#
    )
}

/// Write volume files to the state dir and return (host_path, container_path) pairs
fn prepare_volumes(
    lab_name: &str,
    svc_name: &str,
    volumes: &serde_json::Map<String, serde_json::Value>,
) -> Result<Vec<(String, String)>> {
    let state_dir = service_state_dir(lab_name, svc_name);
    fs::create_dir_all(&state_dir)
        .with_context(|| format!("Failed to create state dir: {}", state_dir.display()))?;

    let mut mounts = Vec::new();

    for (container_path, vol) in volumes {
        if let Some(content) = vol["content"].as_str() {
            // Derive a filename from the container path (e.g. "/config/knot.conf" -> "knot.conf")
            let filename = container_path.rsplit('/').next().unwrap_or("file");
            let host_path = state_dir.join(filename);

            fs::write(&host_path, content)
                .with_context(|| format!("Failed to write {}", host_path.display()))?;

            mounts.push((host_path.display().to_string(), container_path.clone()));
        }
    }

    Ok(mounts)
}

/// Start a single lab service container
pub fn start_service(
    ctx: &CataContext,
    lab_name: &str,
    svc_name: &str,
    svc: &serde_json::Value,
) -> Result<()> {
    let container = svc["container"].as_str().unwrap_or("");
    let image = svc["image"].as_str().unwrap_or("");
    let description = svc["description"].as_str().unwrap_or(svc_name);

    if container.is_empty() || image.is_empty() {
        println!(
            "{} Skipping service '{}' (missing container name or image)",
            style(">>>").yellow(),
            svc_name
        );
        return Ok(());
    }

    if tools::docker::container_running(container) {
        println!("{} {} already running", style(">>>").green(), description);
        return Ok(());
    }

    // Collect port mappings
    let ports: Vec<&str> = svc["ports"]
        .as_array()
        .map(|arr| arr.iter().filter_map(|v| v.as_str()).collect())
        .unwrap_or_default();

    // Write config files and prepare volume mounts
    let mut volume_mounts = if let Some(volumes) = svc["volumes"].as_object() {
        prepare_volumes(lab_name, svc_name, volumes)?
    } else {
        Vec::new()
    };

    // Handle extraMounts (pre-existing files with {{STATE_DIR}} templates)
    if let Some(extra_mounts) = svc["extraMounts"].as_array() {
        let state_dir = lab_state_dir(lab_name);
        for mount in extra_mounts {
            if let (Some(host), Some(container)) =
                (mount["host"].as_str(), mount["container"].as_str())
            {
                let resolved = host.replace("{{STATE_DIR}}", &state_dir.display().to_string());
                volume_mounts.push((resolved, container.to_string()));
            }
        }
    }

    let mount_refs: Vec<(&str, &str)> = volume_mounts
        .iter()
        .map(|(h, c)| (h.as_str(), c.as_str()))
        .collect();

    // Check for extended options (link, networks, dns, networkMode, capAdd)
    let link = svc["link"].as_str();
    let network_mode = svc["networkMode"].as_str();
    let cap_add: Vec<&str> = svc["capAdd"]
        .as_array()
        .map(|arr| arr.iter().filter_map(|v| v.as_str()).collect())
        .unwrap_or_default();
    let networks: Vec<&str> = svc["networks"]
        .as_array()
        .map(|arr| arr.iter().filter_map(|v| v.as_str()).collect())
        .unwrap_or_default();

    // Parse static IP assignments for networks (networkConfig.<network>.ip)
    let mut network_ips = std::collections::HashMap::new();
    if let Some(net_cfg) = svc["networkConfig"].as_object() {
        for (net_name, net_val) in net_cfg {
            if let Some(ip) = net_val["ip"].as_str() {
                network_ips.insert(net_name.clone(), ip.to_string());
            }
        }
    }

    // Optional command override
    let command: Vec<&str> = svc["command"]
        .as_array()
        .map(|arr| arr.iter().filter_map(|v| v.as_str()).collect())
        .unwrap_or_default();

    // Resolve dnsContainers to IPs for --dns flags
    let dns_ips: Vec<String> = svc["dnsContainers"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str())
                .filter_map(|name| tools::docker::get_container_ip(name))
                .collect()
        })
        .unwrap_or_default();

    println!("{} Starting {}...", style(">>>").cyan(), description);

    // Use extended container run if we have any extended options
    if link.is_some()
        || !networks.is_empty()
        || !dns_ips.is_empty()
        || network_mode.is_some()
        || !cap_add.is_empty()
    {
        tools::docker::run_container_extended(
            ctx,
            container,
            image,
            &ports,
            &mount_refs,
            link,
            &networks,
            &dns_ips,
            &command,
            network_mode,
            &cap_add,
            &network_ips,
        )?;
    } else {
        tools::docker::run_container(ctx, container, image, &ports, &mount_refs, &command)?;
    }

    println!("{} {} started", style(">>>").green(), description);

    Ok(())
}

async fn lint_cmd(
    ctx: &CataContext,
    name: Option<String>,
    path: Option<PathBuf>,
    skip: Vec<String>,
) -> Result<()> {
    // Tier 1: Environment — check required tools
    println!("{} Environment", style("catallaxy").cyan().bold(),);
    let tool_results = tools::check_all_tools();
    let mut missing_tools = Vec::new();
    for (name, found, info) in &tool_results {
        if *found {
            println!("  {} {}", style("✓").green(), name);
        } else {
            println!("  {} {} ({})", style("✗").red(), name, info);
            missing_tools.push(name.as_str());
        }
    }
    println!();

    if !missing_tools.is_empty() {
        println!(
            "{} Missing tools: {}",
            style("Warning:").yellow(),
            missing_tools.join(", ")
        );
        println!();
    }

    // Tier 2: Configuration — validate lab config
    let lab_name = match &path {
        Some(_) => None,
        None => Some(ctx.resolve_lab_name(name.as_deref())?),
    };

    if let Some(ref lab_name) = lab_name {
        println!("{} Configuration", style("catallaxy").cyan().bold());
        match crate::nix::get_lab_config(ctx, lab_name) {
            Ok(lab) => {
                let cluster_names: Vec<&str> = lab["clusterNames"]
                    .as_array()
                    .map(|arr| arr.iter().filter_map(|v| v.as_str()).collect())
                    .unwrap_or_default();
                let strategy = lab
                    .pointer("/cd/strategy")
                    .and_then(|v| v.as_str())
                    .unwrap_or("kapp");

                println!("  {} lab: {}", style("✓").green(), lab_name);
                println!("  {} strategy: {}", style("✓").green(), strategy);
                println!(
                    "  {} clusters: {}",
                    style("✓").green(),
                    cluster_names.join(", ")
                );

                // Validate each cluster config loads
                for cluster in &cluster_names {
                    match crate::nix::get_cluster_config_from_lab(&lab, cluster) {
                        Ok(config) => {
                            let provisioner = config["provisioner"].as_str().unwrap_or("unknown");
                            let component_count = config["components"]
                                .as_object()
                                .map(|c| {
                                    c.values()
                                        .filter(|v| {
                                            v.get("enable")
                                                .and_then(|e| e.as_bool())
                                                .unwrap_or(false)
                                        })
                                        .count()
                                })
                                .unwrap_or(0);
                            println!(
                                "    {} {} ({}, {} components)",
                                style("✓").green(),
                                cluster,
                                provisioner,
                                component_count,
                            );
                        }
                        Err(e) => {
                            println!("    {} {} — {}", style("✗").red(), cluster, e,);
                        }
                    }
                }
            }
            Err(e) => {
                println!("  {} lab config failed: {}", style("✗").red(), e);
                bail!("Configuration validation failed");
            }
        }
        println!();
    }

    // Tier 3: Manifests — build and lint
    println!("{} Manifests", style("catallaxy").cyan().bold());
    let package_path = match path {
        Some(p) => p,
        None => {
            let lab_name = lab_name.unwrap();
            println!("  Building...");
            let store_path = crate::nix::build_lab_package(ctx, &lab_name)?;
            PathBuf::from(store_path)
        }
    };

    let passed = lint::run_lint(&package_path, &skip)?;

    if !passed {
        bail!("lint checks failed");
    }

    Ok(())
}

async fn list(ctx: &CataContext) -> Result<()> {
    println!("{} Defined labs", style("catallaxy").cyan().bold());
    println!();

    let names = crate::nix::list_labs(ctx)?;

    if names.is_empty() {
        println!("  (no labs defined)");
        return Ok(());
    }

    for name in &names {
        match crate::nix::get_lab_config(ctx, name) {
            Ok(lab) => {
                let cluster_count = lab["clusterNames"].as_array().map_or(0, |c| c.len());
                println!("  {} ({} clusters)", style(name).green(), cluster_count,);
            }
            Err(_) => {
                println!("  {} (error loading config)", style(name).yellow());
            }
        }
    }

    Ok(())
}

async fn status(ctx: &CataContext, name: &str) -> Result<()> {
    println!("{} Lab '{name}' status", style("catallaxy").cyan().bold());
    println!();

    let lab = crate::nix::get_lab_config(ctx, name)?;

    // Services
    if let Some(services) = lab["services"].as_object() {
        if !services.is_empty() {
            println!("{}", style("Services:").bold());
            for (svc_name, svc) in services {
                let container = svc["container"].as_str().unwrap_or("");
                let description = svc["description"].as_str().unwrap_or("");
                let running = if !container.is_empty() {
                    tools::docker::container_running(container)
                } else {
                    false
                };
                let status_str = if running {
                    style("running").green()
                } else {
                    style("stopped").red()
                };
                println!(
                    "  {} ({}) [{}]",
                    style(svc_name).cyan(),
                    description,
                    status_str
                );
            }
            println!();
        }
    }

    // Clusters
    if let Some(clusters) = lab["clusterNames"].as_array() {
        println!("{}", style("Clusters:").bold());
        for cluster_name in clusters {
            let cluster_name = cluster_name.as_str().unwrap_or("?");
            let context_name = resolve_cluster_context(&lab, cluster_name);
            let reachable = tools::kube::api_reachable(&context_name);

            let status_str = if reachable {
                style("ready").green()
            } else {
                style("not ready").yellow()
            };

            println!(
                "  {} [{}] (context: {})",
                style(cluster_name).green(),
                status_str,
                context_name,
            );
        }
    }

    Ok(())
}

/// Resolve the kube context name for a cluster from its lab config
fn resolve_cluster_context(lab: &serde_json::Value, cluster_name: &str) -> String {
    crate::nix::get_cluster_config_from_lab(lab, cluster_name)
        .ok()
        .and_then(|c| {
            // Prefer explicit kubeContext from Nix config
            c.get("kubeContext")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
                .map(String::from)
                .or_else(|| {
                    // Fallback: k3d naming convention
                    c.pointer("/provisionerConfig/k3d/clusterName")
                        .and_then(|v| v.as_str())
                        .map(|k3d_name| format!("k3d-{k3d_name}"))
                })
        })
        .unwrap_or_else(|| format!("k3d-catallaxy-{cluster_name}"))
}

async fn init(ctx: &CataContext, name: &str) -> Result<()> {
    println!(
        "{} Initializing lab '{name}'",
        style("catallaxy").cyan().bold()
    );

    tools::check_required_tools()?;

    let lab = crate::nix::get_lab_config(ctx, name)?;

    // Step 1: Prerequisites — network, certs, services
    println!();
    println!("{}", style("Step 1: Prerequisites").bold());

    // Create the lab Docker network FIRST (services and clusters join it)
    let network_name = lab
        .pointer("/network/name")
        .and_then(|v| v.as_str())
        .unwrap_or(name);
    let docker_subnet = lab
        .pointer("/network/dockerSubnet")
        .and_then(|v| v.as_str())
        .unwrap_or("172.19.0.0/16");
    println!(
        "{} Ensuring '{}' network exists (subnet: {})...",
        style(">>>").cyan(),
        network_name,
        docker_subnet
    );
    // Compute gateway IP from subnet (first usable IP, e.g. 172.19.0.1)
    let gateway = {
        let base = docker_subnet.split('/').next().unwrap_or("172.19.0.0");
        let octets: Vec<u32> = base.split('.').filter_map(|o| o.parse().ok()).collect();
        if octets.len() == 4 {
            format!(
                "{}.{}.{}.{}",
                octets[0],
                octets[1],
                octets[2],
                octets[3] + 1
            )
        } else {
            "172.19.0.1".to_string()
        }
    };
    let _ = std::process::Command::new("docker")
        .args([
            "network",
            "create",
            "-d",
            "bridge",
            "--subnet",
            docker_subnet,
            "--gateway",
            &gateway,
            network_name,
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();

    // Generate ingress TLS cert if ingress is configured
    if lab.pointer("/services/ingress").is_some() {
        let zone = lab
            .pointer("/dnsInfo/zone")
            .and_then(|v| v.as_str())
            .unwrap_or("lab.test");
        ensure_ingress_cert(name, zone)?;
    }

    // Start infrastructure services (DNS, registry, ingress)
    if let Some(services) = lab["services"].as_object() {
        if !services.is_empty() {
            for (svc_name, svc) in services {
                start_service(ctx, name, svc_name, svc)?;
            }
        }
    }

    // Step 2: Write registries.yaml if registry is enabled (for k3d mirror config)
    let registries_yaml_path =
        if let Some(port) = lab.pointer("/registryPort").and_then(|v| v.as_u64()) {
            let state_dir = service_state_dir(name, "registry");
            fs::create_dir_all(&state_dir)?;
            let path = state_dir.join("registries.yaml");
            let registry_yaml = generate_registries_yaml(port as u16);
            fs::write(&path, registry_yaml)?;
            Some(path)
        } else {
            None
        };

    // Step 3: Provision all clusters via k3d
    let cluster_names: Vec<String> = lab["clusterNames"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();

    if cluster_names.is_empty() {
        println!("{} No clusters defined in lab", style("Warning:").yellow());
        return Ok(());
    }

    println!();
    println!(
        "{}",
        style(format!(
            "Step 2: Provision clusters ({})",
            cluster_names.join(", ")
        ))
        .bold()
    );

    for cluster_name in &cluster_names {
        println!(
            "{} Provisioning cluster '{cluster_name}'...",
            style(">>>").cyan()
        );

        let config = crate::nix::get_cluster_config_from_lab(&lab, cluster_name)?;
        super::cluster::provision_cluster_with_registry(
            ctx,
            cluster_name,
            &config,
            registries_yaml_path.as_ref().map(|p| p.as_path()),
        )?;

        // Connect k3d server to the lab network for cross-cluster and service access
        // (skip when provisioner.k3d.network is set — cluster is already on the lab network)
        let k3d_network = config
            .pointer("/provisionerConfig/k3d/network")
            .and_then(|v| v.as_str());
        if k3d_network.is_none() {
            let k3d_cluster_name = config
                .pointer("/provisionerConfig/k3d/clusterName")
                .and_then(|v| v.as_str())
                .unwrap_or(cluster_name);
            let k3d_server = format!("k3d-{k3d_cluster_name}-server-0");
            let _ = std::process::Command::new("docker")
                .args(["network", "connect", network_name, &k3d_server])
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status();
        }

        println!("{} Cluster '{cluster_name}' is ready", style(">>>").green());
    }

    Ok(())
}

/// Apply manifests to a specific cluster
async fn apply_cluster_components(
    ctx: &CataContext,
    cluster_name: &str,
    dry_run: bool,
    force: bool,
    manifests_dir: Option<String>,
) -> Result<()> {
    println!(
        "{} Applying manifests to cluster '{}'...",
        style(">>>").cyan(),
        cluster_name
    );

    crate::commands::apply::run(
        ctx,
        crate::commands::apply::ApplyArgs {
            cluster: Some(cluster_name.to_string()),
            phase: None,
            component: None,
            dry_run,
            force,
            sequential: false,
            manifests_dir,
        },
    )
    .await
}

async fn up(
    ctx: &CataContext,
    name: &str,
    _phase: Option<String>,
    _component: Option<String>,
    dry_run: bool,
    _force: bool,
) -> Result<()> {
    let lab = crate::nix::get_lab_config(ctx, name)?;

    let steps = lab
        .get("deploymentPlan")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();

    if steps.is_empty() {
        println!("{} No deployment steps for lab '{name}'", style(">>>").yellow());
        return Ok(());
    }

    println!(
        "{} Deploying lab '{name}' ({} steps)",
        style("catallaxy").cyan().bold(),
        steps.len()
    );

    if dry_run {
        println!();
        println!("{} Dry run — showing plan:", style("Note:").yellow());
        plan(ctx, name, false).await?;
        return Ok(());
    }

    // Determine CD strategy — lab up always direct-applies via bootstrap manifests
    let strategy = lab
        .pointer("/cd/strategy")
        .and_then(|v| v.as_str())
        .unwrap_or("kapp");

    // Build manifests once upfront
    println!();
    println!("{} Building lab manifests...", style(">>>").cyan());
    let lab_package = crate::nix::build_lab_package(ctx, name)?;
    println!("{} Lab package built", style(">>>").green());

    // Execute each step
    for (i, step) in steps.iter().enumerate() {
        let step_type = step["type"].as_str().unwrap_or("unknown");
        let description = step["description"].as_str().unwrap_or(step_type);

        println!();
        println!(
            "{} Step {}/{}: {}",
            style(">>>").cyan(),
            i + 1,
            steps.len(),
            style(description).bold(),
        );

        match step_type {
            "setup-services" => {
                // Init services (DNS, registry, ingress, network)
                init(ctx, name).await?;
            }

            "create-cluster" => {
                let cluster_name = step["name"].as_str().unwrap_or("unknown");
                let config = crate::nix::get_cluster_config_from_lab(&lab, cluster_name)?;
                super::cluster::provision_cluster_with_registry(
                    ctx,
                    cluster_name,
                    &config,
                    None, // TODO: registry yaml
                )?;

                // Import lab CA if ingress is configured
                if lab.pointer("/services/ingress").is_some() {
                    import_lab_ca(name, &lab, cluster_name);
                }
            }

            "ensure-secrets" => {
                let stores: Vec<&str> = step["stores"]
                    .as_array()
                    .map(|arr| arr.iter().filter_map(|v| v.as_str()).collect())
                    .unwrap_or_default();

                let flake_root = std::path::PathBuf::from(ctx.flake_uri());
                let mut missing = Vec::new();
                for store_name in &stores {
                    let enc_path = flake_root
                        .join("secrets")
                        .join(name)
                        .join(format!("{store_name}.enc.yaml"));
                    if enc_path.exists() {
                        println!(
                            "{} Store '{}' exists",
                            style(">>>").green(),
                            store_name
                        );
                    } else {
                        missing.push(*store_name);
                    }
                }

                if !missing.is_empty() {
                    bail!(
                        "Missing secret stores: {}\n\
                         Run these commands first:\n  \
                         cata secrets generate\n  \
                         cata secrets edit {}",
                        missing.join(", "),
                        missing.first().unwrap_or(&""),
                    );
                }
            }

            "deploy-manifests" => {
                let target = step["target"].as_str().unwrap_or("unknown");
                // Use bootstrap/ (kapp format) for direct-apply; manifests/ is strategy-specific
                let subdir = if strategy == "kapp" { "manifests" } else { "bootstrap" };
                let cluster_manifests = format!("{lab_package}/{subdir}/{target}");

                if std::path::Path::new(&cluster_manifests).exists() {
                    // lab up always forces — it's a bootstrap path
                    apply_cluster_components(ctx, target, dry_run, true, Some(cluster_manifests))
                        .await?;
                } else {
                    println!(
                        "{} No manifests for '{}', skipping",
                        style(">>>").yellow(),
                        target
                    );
                }
            }

            "wait-for-resources" => {
                let target = step["target"].as_str().unwrap_or("unknown");
                let context = resolve_cluster_context(&lab, target);

                if let Some(resources) = step["resources"].as_array() {
                    for resource in resources {
                        let res_name = resource["name"].as_str().unwrap_or("?");
                        println!("{} Waiting for '{res_name}' to be ready...", style(">>>").cyan());

                        // Poll until the resource is READY
                        let start = std::time::Instant::now();
                        let timeout = std::time::Duration::from_secs(600);
                        loop {
                            // Check Crossplane managed resource readiness
                            let output = std::process::Command::new("kubectl")
                                .args([
                                    "--context", &context,
                                    "get", "managed",
                                    "--field-selector", &format!("metadata.name={res_name}"),
                                    "-o", "jsonpath={.items[0].status.conditions[?(@.type==\"Ready\")].status}",
                                ])
                                .output();

                            if let Ok(ref o) = output {
                                let status = String::from_utf8_lossy(&o.stdout);
                                if status.trim() == "True" {
                                    println!("{} '{res_name}' is ready", style(">>>").green());
                                    break;
                                }
                            }

                            if start.elapsed() > timeout {
                                bail!("Timed out waiting for '{res_name}' to be ready");
                            }

                            println!("  waiting... ({}s elapsed)", start.elapsed().as_secs());
                            tokio::time::sleep(tokio::time::Duration::from_secs(15)).await;
                        }
                    }
                }
            }

            "sync-kubeconfig" => {
                if let Some(clusters) = step["clusters"].as_array() {
                    let target = step.get("target")
                        .and_then(|v| v.as_str())
                        .or_else(|| steps.iter()
                            .find(|s| s["type"].as_str() == Some("create-cluster"))
                            .and_then(|s| s["name"].as_str()))
                        .unwrap_or("mgmt");
                    let context = resolve_cluster_context(&lab, target);

                    for cluster_val in clusters {
                        let cluster_name = cluster_val.as_str().unwrap_or("?");
                        println!("{} Syncing kubeconfig for '{cluster_name}'...", style(">>>").cyan());

                        match sync_crossplane_kubeconfig(&context, cluster_name) {
                            Ok(()) => {
                                println!("{} Kubeconfig synced for '{cluster_name}'", style(">>>").green());
                            }
                            Err(e) => {
                                println!(
                                    "{} Failed to sync kubeconfig for '{cluster_name}': {e}",
                                    style("Warning:").yellow()
                                );
                            }
                        }
                    }
                }
            }

            "pivot" => {
                let from = step["from"].as_str().unwrap_or("?");
                let to = step["to"].as_str().unwrap_or("?");
                println!("{} Pivoting from '{from}' to '{to}'...", style(">>>").cyan());
                println!("{} Pivot not yet implemented", style("Warning:").yellow());
            }

            "destroy-cluster" => {
                let cluster_name = step["name"].as_str().unwrap_or("unknown");
                println!("{} Destroying ephemeral cluster '{cluster_name}'...", style(">>>").cyan());
                let config = crate::nix::get_cluster_config_from_lab(&lab, cluster_name)?;
                super::cluster::deprovision_cluster(ctx, cluster_name, &config)?;
            }

            "run-script" => {
                let bin = step["bin"].as_str().unwrap_or("");
                if !bin.is_empty() {
                    let status = std::process::Command::new(bin).status();
                    if let Ok(s) = status {
                        if !s.success() {
                            println!("{} Script failed (exit {})", style("Warning:").yellow(), s.code().unwrap_or(-1));
                        }
                    }
                }
            }

            other => {
                println!("{} Unknown step type: {other}", style("Warning:").yellow());
            }
        }
    }

    // Summary
    println!();
    println!("{} Lab '{}' is up", style("catallaxy").cyan().bold(), name);

    Ok(())
}

/// Import lab CA certificate into a cluster for cert-manager
fn import_lab_ca(lab_name: &str, lab: &serde_json::Value, cluster_name: &str) {
    let ingress_dir = service_state_dir(lab_name, "ingress");
    let ca_crt = ingress_dir.join("ca.crt");
    let ca_key = ingress_dir.join("ca.key");

    if !ca_crt.exists() || !ca_key.exists() {
        return;
    }

    let context = resolve_cluster_context(lab, cluster_name);

    let _ = std::process::Command::new("kubectl")
        .args(["--context", &context, "create", "namespace", "cert-manager"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();

    let _ = std::process::Command::new("kubectl")
        .args(["--context", &context, "delete", "secret", "lab-ca-ca-secret", "-n", "cert-manager"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();

    let status = std::process::Command::new("kubectl")
        .args(["--context", &context, "create", "secret", "tls", "lab-ca-ca-secret", "-n", "cert-manager", "--cert"])
        .arg(&ca_crt)
        .args(["--key"])
        .arg(&ca_key)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();

    match status {
        Ok(s) if s.success() => {
            println!("{} Lab CA imported into '{cluster_name}'", style(">>>").green());
        }
        _ => {
            println!("{} Failed to import CA into '{cluster_name}'", style(">>>").yellow());
        }
    }
}

/// Find the CAPI management cluster in a lab config
fn find_capi_mgmt_cluster(
    lab: &serde_json::Value,
) -> Option<(String, serde_json::Value)> {
    let clusters = lab.pointer("/clusters")?.as_object()?;
    for (name, config) in clusters {
        if config
            .pointer("/components/cluster-api/isManagementCluster")
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
        {
            return Some((name.clone(), config.clone()));
        }
    }
    None
}

/// Get enabled CAPI cluster names from a management cluster's config
fn get_capi_cluster_names(mgmt_config: &serde_json::Value) -> Vec<String> {
    mgmt_config
        .pointer("/components/cluster-api/clusters")
        .and_then(|v| v.as_object())
        .map(|clusters| {
            clusters
                .iter()
                .filter(|(_, v)| {
                    v.get("enable")
                        .and_then(|e| e.as_bool())
                        .unwrap_or(true)
                })
                .map(|(name, _)| name.clone())
                .collect()
        })
        .unwrap_or_default()
}

/// Sync a CAPI-managed cluster's kubeconfig into ~/.kube/config.
/// Waits for the kubeconfig secret to appear, then extracts and merges it.
fn sync_capi_kubeconfig(
    mgmt_context: &str,
    cluster_name: &str,
    namespace: &str,
    timeout: &str,
) -> Result<()> {
    use std::time::{Duration, Instant};

    let timeout_secs: u64 = timeout
        .trim_end_matches('m')
        .parse::<u64>()
        .unwrap_or(10)
        * 60;
    let timeout_duration = Duration::from_secs(timeout_secs);
    let start = Instant::now();

    // Wait for kubeconfig secret to exist
    loop {
        match tools::kube::get_capi_kubeconfig(mgmt_context, cluster_name, namespace) {
            Ok(kubeconfig_content) if !kubeconfig_content.trim().is_empty() => {
                // Save to file
                let kube_dir = dirs::home_dir().unwrap_or_default().join(".kube");
                std::fs::create_dir_all(&kube_dir)?;
                let kube_path = kube_dir.join(format!("{cluster_name}.kubeconfig"));
                std::fs::write(&kube_path, &kubeconfig_content)?;

                // Merge into default kubeconfig
                let context_name = format!("{cluster_name}-admin");
                tools::kube::merge_kubeconfig(&kube_path, &context_name)?;

                return Ok(());
            }
            _ => {
                if start.elapsed() > timeout_duration {
                    bail!(
                        "Timed out waiting for kubeconfig for '{cluster_name}' ({}s elapsed)",
                        timeout_duration.as_secs()
                    );
                }
                println!("  waiting... ({}s elapsed)", start.elapsed().as_secs());
                std::thread::sleep(Duration::from_secs(10));
            }
        }
    }
}

async fn apply(
    ctx: &CataContext,
    name: &str,
    phase: Option<String>,
    component: Option<String>,
    dry_run: bool,
    force: bool,
) -> Result<()> {
    let lab = crate::nix::get_lab_config(ctx, name)?;

    println!("{} Applying lab '{name}'", style("catallaxy").cyan().bold());

    // Build the lab package once — contains all clusters' rendered manifests
    println!("{} Building lab manifests...", style(">>>").cyan());
    let lab_package = crate::nix::build_lab_package(ctx, name)?;

    let cluster_names: Vec<String> = lab["clusterNames"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();

    for cluster_name in &cluster_names {
        let cluster_manifests = format!("{lab_package}/manifests/{cluster_name}");
        crate::commands::apply::run(
            ctx,
            crate::commands::apply::ApplyArgs {
                cluster: Some(cluster_name.to_string()),
                phase: phase.clone(),
                component: component.clone(),
                dry_run,
                force,
                sequential: false,
                manifests_dir: Some(cluster_manifests),
            },
        )
        .await?;
    }

    Ok(())
}

async fn ops(ctx: &CataContext, name: &str, args: &[String]) -> Result<()> {
    let lab = crate::nix::get_lab_config(ctx, name)?;

    let ops_tool_path = lab.pointer("/opsToolPath").and_then(|v| v.as_str());

    match ops_tool_path {
        Some(path) if !path.is_empty() => {
            let status = std::process::Command::new(path)
                .args(args)
                .status()
                .with_context(|| format!("Failed to run ops tool: {}", path))?;

            if !status.success() {
                std::process::exit(status.code().unwrap_or(1));
            }
            Ok(())
        }
        _ => {
            println!(
                "{} No ops commands defined for lab '{name}'.",
                style(">>>").yellow()
            );
            println!("  Define commands in lab.ops.commands in your lab config.");
            Ok(())
        }
    }
}

async fn publish(
    ctx: &CataContext,
    name: &str,
    pr: bool,
    message: Option<String>,
    dry_run: bool,
) -> Result<()> {
    use std::process::Command;

    let lab = crate::nix::get_lab_config(ctx, name)?;

    let git_cfg = lab.pointer("/cd/git");
    let repo = git_cfg.and_then(|g| g["repo"].as_str()).unwrap_or("");

    if repo.is_empty() {
        bail!("No git repo configured. Set lab.cd.git.repo in your lab config.");
    }

    let branch = git_cfg.and_then(|g| g["branch"].as_str()).unwrap_or("main");
    let repo_path = git_cfg.and_then(|g| g["path"].as_str()).unwrap_or("");
    let provider = git_cfg
        .and_then(|g| g["provider"].as_str())
        .unwrap_or("github");
    let pr_enabled = pr
        || git_cfg
            .and_then(|g| g["prEnabled"].as_bool())
            .unwrap_or(false);
    let pr_base = git_cfg
        .and_then(|g| g["prBaseBranch"].as_str())
        .unwrap_or("main");

    println!(
        "{} Publishing manifests for lab '{name}'",
        style("catallaxy").cyan().bold()
    );

    // Build the lab package
    println!("{} Building lab manifests...", style(">>>").cyan());
    let package_path = crate::nix::build_lab_package(ctx, name)?;

    let manifests_src = format!("{}/manifests", package_path);
    if !std::path::Path::new(&manifests_src).exists() {
        bail!("No manifests found at {}", manifests_src);
    }

    if dry_run {
        println!("{} Dry run — would publish to:", style(">>>").yellow());
        println!("  Repo: {}", repo);
        println!("  Branch: {}", branch);
        println!(
            "  Path: {}",
            if repo_path.is_empty() { "/" } else { repo_path }
        );
        println!("  PR: {}", pr_enabled);
        println!();
        println!("  Manifests: {}", manifests_src);

        // List what would be published
        let status = Command::new("find")
            .args([&manifests_src, "-type", "f", "-name", "*.yaml"])
            .status();
        let _ = status;
        return Ok(());
    }

    // Clone the target repo into a temp dir
    let tmp_dir = tempfile::tempdir().context("Failed to create temp directory")?;
    let clone_dir = tmp_dir.path().join("repo");

    println!("{} Cloning {}...", style(">>>").cyan(), repo);

    let status = Command::new("git")
        .args(["clone", "--depth", "1", "--branch", branch, repo])
        .arg(&clone_dir)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .context("Failed to clone git repo")?;

    if !status.success() {
        // Try without --branch (repo might be empty)
        let status = Command::new("git")
            .args(["clone", repo])
            .arg(&clone_dir)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .context("Failed to clone git repo")?;

        if !status.success() {
            bail!("Failed to clone {}", repo);
        }
    }

    // Determine the target directory within the repo
    let target_dir = if repo_path.is_empty() {
        clone_dir.clone()
    } else {
        clone_dir.join(repo_path)
    };

    // Create a working branch for PR mode
    let work_branch = if pr_enabled {
        let branch_name = format!("catallaxy/{name}/{}", chrono_simple_timestamp());
        let status = Command::new("git")
            .args(["-C"])
            .arg(&clone_dir)
            .args(["checkout", "-b", &branch_name])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()?;
        if !status.success() {
            bail!("Failed to create branch {}", branch_name);
        }
        Some(branch_name)
    } else {
        None
    };

    // Sync manifests: remove old, copy new
    let manifests_target = target_dir.join("manifests");
    if manifests_target.exists() {
        fs::remove_dir_all(&manifests_target)?;
    }

    println!("{} Copying manifests...", style(">>>").cyan());

    // Copy from nix store (read-only) to the repo dir
    let status = Command::new("cp")
        .args(["-rL"])
        .arg(&manifests_src)
        .arg(&target_dir)
        .status()
        .context("Failed to copy manifests")?;

    if !status.success() {
        bail!("Failed to copy manifests to repo");
    }

    // Also copy metadata.json
    let metadata_src = format!("{}/metadata.json", package_path);
    if std::path::Path::new(&metadata_src).exists() {
        fs::copy(&metadata_src, target_dir.join("metadata.json"))?;
    }

    // Git add + commit
    let commit_msg =
        message.unwrap_or_else(|| format!("chore(catallaxy): update manifests for lab '{name}'"));

    let status = Command::new("git")
        .args(["-C"])
        .arg(&clone_dir)
        .args(["add", "-A"])
        .status()?;
    if !status.success() {
        bail!("git add failed");
    }

    // Check if there are changes to commit
    let diff_status = Command::new("git")
        .args(["-C"])
        .arg(&clone_dir)
        .args(["diff", "--cached", "--quiet"])
        .status()?;

    if diff_status.success() {
        println!(
            "{} No changes to publish — manifests are up to date",
            style(">>>").green()
        );
        return Ok(());
    }

    let status = Command::new("git")
        .args(["-C"])
        .arg(&clone_dir)
        .args(["commit", "-m", &commit_msg])
        .stdout(std::process::Stdio::null())
        .status()?;
    if !status.success() {
        bail!("git commit failed");
    }

    // Push
    let push_branch = work_branch.as_deref().unwrap_or(branch);
    println!(
        "{} Pushing to {} (branch: {})...",
        style(">>>").cyan(),
        repo,
        push_branch
    );

    let status = Command::new("git")
        .args(["-C"])
        .arg(&clone_dir)
        .args(["push", "origin", push_branch])
        .status()?;
    if !status.success() {
        bail!("git push failed");
    }

    // Create PR/MR if enabled
    if pr_enabled {
        let work_branch = work_branch.as_deref().unwrap();
        println!(
            "{} Creating PR: {} → {}...",
            style(">>>").cyan(),
            work_branch,
            pr_base
        );

        let pr_title = format!("Update manifests for lab '{name}'");
        let pr_body = format!("Automated manifest update from `cata lab publish`.\n\nLab: {name}");

        let pr_result = match provider {
            "github" => Command::new("gh")
                .args(["-C"])
                .arg(&clone_dir)
                .args([
                    "pr",
                    "create",
                    "--title",
                    &pr_title,
                    "--body",
                    &pr_body,
                    "--base",
                    pr_base,
                    "--head",
                    work_branch,
                ])
                .status(),
            "gitlab" => Command::new("glab")
                .args(["-C"])
                .arg(&clone_dir)
                .args([
                    "mr",
                    "create",
                    "--title",
                    &pr_title,
                    "--description",
                    &pr_body,
                    "--target-branch",
                    pr_base,
                    "--source-branch",
                    work_branch,
                ])
                .status(),
            _ => {
                println!(
                    "{} PR creation not yet supported for provider '{}'. Push succeeded — create PR manually.",
                    style(">>>").yellow(),
                    provider
                );
                return Ok(());
            }
        };

        match pr_result {
            Ok(s) if s.success() => {
                println!("{} PR created successfully", style(">>>").green());
            }
            _ => {
                println!(
                    "{} PR creation may have failed. Push succeeded — check manually.",
                    style(">>>").yellow()
                );
            }
        }
    }

    println!("{} Manifests published to {}", style(">>>").green(), repo);

    Ok(())
}

/// Simple timestamp for branch names (YYYYMMDD-HHMMSS)
fn chrono_simple_timestamp() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    // Convert to rough YYYYMMDD-HHMMSS without chrono dependency
    format!("{}", secs)
}

/// Sync kubeconfig for a Crossplane-provisioned DOKS cluster.
/// Gets the cluster ID from the Crossplane resource, the DO token from the credentials secret,
/// and fetches the kubeconfig via the DO API.
fn sync_crossplane_kubeconfig(mgmt_context: &str, cluster_name: &str) -> Result<()> {
    // Get cluster ID from Crossplane managed resource
    let id_output = std::process::Command::new("kubectl")
        .args([
            "--context", mgmt_context,
            "get", "clusters.kubernetes.digitalocean.crossplane.io", cluster_name,
            "-o", "jsonpath={.status.atProvider.id}",
        ])
        .output()
        .context("Failed to get cluster ID")?;

    let cluster_id = String::from_utf8_lossy(&id_output.stdout).trim().to_string();
    if cluster_id.is_empty() {
        bail!("No cluster ID found for '{cluster_name}'");
    }

    // Get DO token from the credentials secret
    let token_output = std::process::Command::new("kubectl")
        .args([
            "--context", mgmt_context,
            "get", "secret", "do-credentials", "-n", "crossplane-system",
            "-o", "jsonpath={.data.credentials}",
        ])
        .output()
        .context("Failed to get DO credentials")?;

    let creds_b64 = String::from_utf8_lossy(&token_output.stdout).trim().to_string();
    let creds_json = String::from_utf8(
        base64::Engine::decode(&base64::engine::general_purpose::STANDARD, &creds_b64)
            .context("Failed to decode credentials")?,
    )?;
    let token: String = serde_json::from_str::<serde_json::Value>(&creds_json)?
        .get("token")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow::anyhow!("No token in credentials"))?
        .to_string();

    // Fetch kubeconfig via DO API
    let kubeconfig_output = std::process::Command::new("curl")
        .args([
            "-s",
            "-H", &format!("Authorization: Bearer {token}"),
            &format!("https://api.digitalocean.com/v2/kubernetes/clusters/{cluster_id}/kubeconfig"),
        ])
        .output()
        .context("Failed to fetch kubeconfig from DO API")?;

    let kubeconfig = String::from_utf8_lossy(&kubeconfig_output.stdout);
    if !kubeconfig.contains("apiVersion") {
        bail!("Invalid kubeconfig response from DO API");
    }

    // Save and rename context to match cluster name
    let kube_dir = dirs::home_dir().unwrap_or_default().join(".kube");
    std::fs::create_dir_all(&kube_dir)?;
    let kube_path = kube_dir.join(format!("{cluster_name}.kubeconfig"));
    std::fs::write(&kube_path, kubeconfig.as_bytes())?;

    // Find the original context name from the downloaded kubeconfig and rename it
    let orig_ctx = std::process::Command::new("kubectl")
        .env("KUBECONFIG", kube_path.display().to_string())
        .args(["config", "current-context"])
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
            } else {
                None
            }
        });

    if let Some(ref orig) = orig_ctx {
        if orig != cluster_name {
            let _ = std::process::Command::new("kubectl")
                .env("KUBECONFIG", kube_path.display().to_string())
                .args(["config", "rename-context", orig, cluster_name])
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status();
        }
    }

    tools::kube::merge_kubeconfig(&kube_path, cluster_name)?;

    Ok(())
}

/// Show the computed deployment plan
async fn plan(ctx: &CataContext, name: &str, teardown: bool) -> Result<()> {
    let lab = crate::nix::get_lab_config(ctx, name)?;

    let (plan_key, plan_label) = if teardown {
        ("teardownPlan", "Teardown")
    } else {
        ("deploymentPlan", "Deployment")
    };

    println!(
        "{} {} plan for '{name}'",
        style("catallaxy").cyan().bold(),
        plan_label,
    );
    println!();

    if let Some(steps) = lab.get(plan_key).and_then(|v| v.as_array()) {
        for (i, step) in steps.iter().enumerate() {
            let step_type = step["type"].as_str().unwrap_or("unknown");
            let description = step["description"].as_str().unwrap_or("");

            let icon = match step_type {
                "setup-services" => "🔧",
                "create-cluster" => "📦",
                "deploy-manifests" => "🚀",
                "inject-secrets" | "ensure-secrets" => "🔑",
                "wait-for-resources" => "⏳",
                "sync-kubeconfig" => "🔗",
                "pivot" => "🔄",
                "destroy-cluster" => "💥",
                "run-script" => "⚡",
                "teardown-hooks" => "🧹",
                "remove-services" => "🔧",
                "remove-network" => "🌐",
                "remove-trust" => "🔒",
                _ => "•",
            };

            println!(
                "  {} {} {}",
                style(format!("{}.", i + 1)).dim(),
                icon,
                description,
            );

            // Show step details
            match step_type {
                "create-cluster" => {
                    let provisioner = step["provisioner"].as_str().unwrap_or("unknown");
                    let name = step["name"].as_str().unwrap_or("?");
                    let ephemeral = step["ephemeral"].as_bool().unwrap_or(false);
                    println!(
                        "     {} provisioner={}, ephemeral={}",
                        style("→").dim(),
                        provisioner,
                        ephemeral
                    );
                    let _ = name; // used in description
                }
                "deploy-manifests" => {
                    let target = step["target"].as_str().unwrap_or("?");
                    println!("     {} target={}", style("→").dim(), target);
                }
                "wait-for-resources" => {
                    let target = step["target"].as_str().unwrap_or("?");
                    if let Some(resources) = step["resources"].as_array() {
                        let names: Vec<&str> = resources
                            .iter()
                            .filter_map(|r| r["name"].as_str())
                            .collect();
                        println!(
                            "     {} on={}, waiting for: {}",
                            style("→").dim(),
                            target,
                            names.join(", ")
                        );
                    }
                }
                "sync-kubeconfig" => {
                    let source = step["source"].as_str().unwrap_or("?");
                    if let Some(clusters) = step["clusters"].as_array() {
                        let names: Vec<&str> =
                            clusters.iter().filter_map(|c| c.as_str()).collect();
                        println!(
                            "     {} via={}, clusters: {}",
                            style("→").dim(),
                            source,
                            names.join(", ")
                        );
                    }
                }
                "pivot" => {
                    let from = step["from"].as_str().unwrap_or("?");
                    let to = step["to"].as_str().unwrap_or("?");
                    println!("     {} {} → {}", style("→").dim(), from, to);
                }
                "teardown-hooks" | "destroy-cluster" => {
                    let target = step["target"]
                        .as_str()
                        .or_else(|| step["name"].as_str())
                        .unwrap_or("?");
                    println!("     {} cluster={}", style("→").dim(), target);
                }
                _ => {}
            }
        }

        println!();
        println!(
            "  {} steps total",
            style(steps.len().to_string()).bold()
        );
    } else {
        println!("  (no {} plan computed)", plan_label.to_lowercase());
    }

    Ok(())
}

/// Stop lab clusters (preserves state, restartable with `lab up`)
async fn down(ctx: &CataContext, name: &str) -> Result<()> {
    println!(
        "{} Stopping lab '{name}' (use 'lab destroy' to delete everything)",
        style("catallaxy").cyan().bold()
    );

    let lab = crate::nix::get_lab_config(ctx, name)?;

    let cluster_names: Vec<String> = lab["clusterNames"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();

    if !cluster_names.is_empty() {
        println!();
        println!("{}", style("Clusters:").bold());

        for cluster_name in &cluster_names {
            match crate::nix::get_cluster_config_from_lab(&lab, cluster_name) {
                Ok(config) => {
                    println!(
                        "{} Stopping cluster '{cluster_name}'...",
                        style(">>>").cyan()
                    );
                    if let Err(e) = super::cluster::stop_cluster(ctx, cluster_name, &config) {
                        println!(
                            "{} Failed to stop '{}': {}",
                            style("Warning:").yellow(),
                            cluster_name,
                            e
                        );
                    }
                }
                Err(e) => {
                    println!(
                        "{} Failed to load config for '{}': {}",
                        style("Warning:").yellow(),
                        cluster_name,
                        e
                    );
                }
            }
        }
    }

    println!();
    println!(
        "{} Lab '{name}' is stopped. Run 'lab up' to resume.",
        style("catallaxy").cyan().bold()
    );

    Ok(())
}

/// Destroy lab completely — teardown hooks, delete clusters, remove services/network/CA
async fn destroy(ctx: &CataContext, name: &str) -> Result<()> {
    println!(
        "{} Destroying lab '{name}'",
        style("catallaxy").cyan().bold()
    );

    let lab = crate::nix::get_lab_config(ctx, name)?;

    let steps = lab
        .get("teardownPlan")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();

    if steps.is_empty() {
        println!("{} No teardown steps for lab '{name}'", style(">>>").yellow());
        return Ok(());
    }

    // Build lab package to realize teardown hook binaries (nix eval gives
    // store paths but doesn't build them)
    let has_hooks = steps.iter().any(|s| s["type"].as_str() == Some("teardown-hooks"));
    if has_hooks {
        println!("{} Building teardown hooks...", style(">>>").cyan());
        crate::nix::build_lab_package(ctx, name)?;
    }

    println!(
        "{} Teardown plan ({} steps)",
        style(">>>").cyan(),
        steps.len()
    );

    for (i, step) in steps.iter().enumerate() {
        let step_type = step["type"].as_str().unwrap_or("unknown");
        let description = step["description"].as_str().unwrap_or(step_type);

        println!();
        println!(
            "{} Step {}/{}: {}",
            style(">>>").cyan(),
            i + 1,
            steps.len(),
            style(description).bold(),
        );

        match step_type {
            "teardown-hooks" => {
                let target = step["target"].as_str().unwrap_or("unknown");
                let config = crate::nix::get_cluster_config_from_lab(&lab, target)?;

                if let Some(hooks) = config
                    .pointer("/lifecycle/teardown")
                    .and_then(|v| v.as_array())
                {
                    for hook in hooks {
                        let hook_name = hook["name"].as_str().unwrap_or("unknown");
                        let hook_desc = hook["description"].as_str().unwrap_or(hook_name);
                        let bin = hook["bin"].as_str().unwrap_or("");

                        if bin.is_empty() {
                            continue;
                        }

                        println!(
                            "{} [{}] {}...",
                            style(">>>").cyan(),
                            target,
                            hook_desc,
                        );

                        match std::process::Command::new(bin).status() {
                            Ok(s) if s.success() => {
                                println!(
                                    "{} [{}] {} complete",
                                    style(">>>").green(),
                                    target,
                                    hook_name,
                                );
                            }
                            Ok(s) => {
                                println!(
                                    "{} [{}] {} failed (exit {})",
                                    style("ERROR").red(),
                                    target,
                                    hook_name,
                                    s.code().unwrap_or(-1),
                                );
                                println!(
                                    "{} Cloud resources may not have been fully cleaned up!",
                                    style("Warning:").yellow(),
                                );
                            }
                            Err(e) => {
                                println!(
                                    "{} [{}] {} failed: {}",
                                    style("ERROR").red(),
                                    target,
                                    hook_name,
                                    e,
                                );
                                println!(
                                    "{} Cloud resources may not have been fully cleaned up!",
                                    style("Warning:").yellow(),
                                );
                            }
                        }
                    }
                }
            }

            "destroy-cluster" => {
                let cluster_name = step["name"].as_str().unwrap_or("unknown");
                match crate::nix::get_cluster_config_from_lab(&lab, cluster_name) {
                    Ok(config) => {
                        if let Err(e) =
                            super::cluster::deprovision_cluster(ctx, cluster_name, &config)
                        {
                            println!(
                                "{} Failed to destroy '{}': {}",
                                style("Warning:").yellow(),
                                cluster_name,
                                e
                            );
                        }
                    }
                    Err(e) => {
                        println!(
                            "{} Failed to load config for '{}': {}",
                            style("Warning:").yellow(),
                            cluster_name,
                            e
                        );
                    }
                }

                if let Err(e) = kubeconfig::cleanup_kubeconfig(ctx, cluster_name) {
                    println!(
                        "{} Failed to cleanup kubeconfig for '{}': {}",
                        style("Warning:").yellow(),
                        cluster_name,
                        e
                    );
                }
            }

            "remove-services" => {
                if let Some(services) = lab["services"].as_object() {
                    for (svc_name, svc) in services {
                        let container = svc["container"].as_str().unwrap_or("");
                        let svc_desc = svc["description"].as_str().unwrap_or(svc_name);

                        if container.is_empty() {
                            continue;
                        }

                        println!("{} Removing {}...", style(">>>").cyan(), svc_desc);
                        tools::docker::stop_container(ctx, container)?;
                        println!("{} {} removed", style(">>>").green(), svc_desc);
                    }
                }
            }

            "remove-network" => {
                let network_name = lab
                    .pointer("/network/name")
                    .and_then(|v| v.as_str())
                    .unwrap_or(name);

                println!(
                    "{} Removing Docker network '{}'...",
                    style(">>>").cyan(),
                    network_name
                );
                let _ = std::process::Command::new("docker")
                    .args(["network", "rm", network_name])
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .status();
            }

            "remove-trust" => {
                println!("{} Cleaning up browser CA trust...", style(">>>").cyan());
                if let Err(e) = trust_teardown(name).await {
                    println!(
                        "{} Failed to remove CA trust: {} (may not have been set up)",
                        style(">>>").yellow(),
                        e
                    );
                }
            }

            other => {
                println!("{} Unknown teardown step type: {other}", style("Warning:").yellow());
            }
        }
    }

    println!();
    println!(
        "{} Lab '{}' destroyed",
        style("catallaxy").cyan().bold(),
        name
    );

    Ok(())
}

async fn dns(ctx: &CataContext, name: &str, setup: bool, teardown: bool) -> Result<()> {
    let lab = crate::nix::get_lab_config(ctx, name)?;

    let dns_info = lab.get("dnsInfo");
    if dns_info.is_none() || dns_info.unwrap().is_null() {
        println!(
            "{} No DNS configured (enable lab.dns to use local DNS resolution)",
            style(">>>").yellow()
        );
        return Ok(());
    }

    let dns_info = dns_info.unwrap();
    let host = dns_info["host"].as_str().unwrap_or("127.0.0.1");
    let port = dns_info["port"].as_u64().unwrap_or(5353);
    let zone = dns_info["zone"].as_str().unwrap_or("lab.test");

    let docker_subnet = lab
        .pointer("/network/dockerSubnet")
        .and_then(|v| v.as_str())
        .unwrap_or("172.19.0.0/16");

    if teardown {
        return dns_teardown(zone, docker_subnet).await;
    }

    if setup {
        return dns_setup(host, port, zone, docker_subnet).await;
    }

    // Default: show instructions
    println!("{} Lab DNS Configuration", style("catallaxy").cyan().bold());
    println!();
    println!("DNS Server: {}:{}", host, port);
    println!("Zone: {}", zone);
    println!();
    println!("To resolve *.{} from your terminal:", zone);
    println!();

    println!("{}", style("macOS:").bold());
    println!("  sudo mkdir -p /etc/resolver");
    println!(
        "  echo -e \"nameserver {}\\nport {}\" | sudo tee /etc/resolver/{}",
        host, port, zone
    );
    println!();

    println!("{}", style("Linux (systemd-resolved):").bold());
    println!("  sudo mkdir -p /etc/systemd/resolved.conf.d");
    println!(
        "  cat <<EOF | sudo tee /etc/systemd/resolved.conf.d/{}.conf",
        zone.replace('.', "-")
    );
    println!("  [Resolve]");
    println!("  DNS={}:{}", host, port);
    println!("  Domains=~{}", zone);
    println!("  EOF");
    println!("  sudo systemctl restart systemd-resolved");
    println!();

    println!("{}", style("Linux (dnsmasq):").bold());
    println!("  Add to /etc/dnsmasq.conf:");
    println!("  server=/{}/{}#{}", zone, host, port);
    println!();

    println!("{}", style("Test:").bold());
    println!("  dig @{} -p {} git.{}", host, port, zone);
    println!();

    println!("{}", style("Auto-configure:").bold());
    println!("  cata lab dns --setup     # Configure resolver (requires sudo)");
    println!("  cata lab dns --teardown  # Remove configuration");

    Ok(())
}

async fn dns_setup(host: &str, port: u64, zone: &str, docker_subnet: &str) -> Result<()> {
    println!(
        "{} Setting up DNS resolution for *.{}",
        style(">>>").cyan(),
        zone
    );

    if cfg!(target_os = "macos") {
        dns_setup_macos(host, port, zone, docker_subnet)
    } else {
        dns_setup_linux(host, port, zone)
    }
}

fn dns_setup_macos(host: &str, port: u64, zone: &str, docker_subnet: &str) -> Result<()> {
    use std::process::Command;

    let resolver_dir = "/etc/resolver";
    let resolver_file = format!("{}/{}", resolver_dir, zone);

    // Check if already configured
    if std::path::Path::new(&resolver_file).exists() {
        let content = fs::read_to_string(&resolver_file).unwrap_or_default();
        if content.contains(&format!("port {}", port)) {
            println!(
                "{} DNS resolver already configured at {}",
                style(">>>").green(),
                resolver_file
            );
        }
    } else {
        let resolver_content = format!("nameserver {}\nport {}\n", host, port);

        println!("{} Creating {}...", style(">>>").cyan(), resolver_file);

        // Create directory with sudo
        let mkdir_status = Command::new("sudo")
            .args(["mkdir", "-p", resolver_dir])
            .status()
            .context("Failed to run sudo mkdir")?;

        if !mkdir_status.success() {
            bail!("Failed to create {}", resolver_dir);
        }

        // Write resolver file with sudo tee
        let mut tee = Command::new("sudo")
            .args(["tee", &resolver_file])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null())
            .spawn()
            .context("Failed to run sudo tee")?;

        if let Some(stdin) = tee.stdin.as_mut() {
            stdin.write_all(resolver_content.as_bytes())?;
        }

        let tee_status = tee.wait()?;
        if !tee_status.success() {
            bail!("Failed to write {}", resolver_file);
        }

        println!(
            "{} DNS resolver configured at {}",
            style(">>>").green(),
            resolver_file
        );
    }

    // Add route to Docker subnet via Colima VM so the host can reach
    // Docker-network IPs (DNS records point to real container IPs)
    if let Some(colima_ip) = get_colima_vm_ip() {
        println!(
            "{} Adding route to {} via Colima VM ({})...",
            style(">>>").cyan(),
            docker_subnet,
            colima_ip
        );
        let status = Command::new("sudo")
            .args(["route", "-n", "add", "-net", docker_subnet, &colima_ip])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
        match status {
            Ok(s) if s.success() => {
                println!(
                    "{} Route added: {} → {}",
                    style(">>>").green(),
                    docker_subnet,
                    colima_ip
                );
            }
            _ => {
                println!(
                    "{} Route may already exist (continuing)",
                    style(">>>").yellow()
                );
            }
        }
    }

    println!();
    println!("Test with: dig git.{}", zone);

    Ok(())
}

/// Get the Colima VM IP address (for routing Docker subnet traffic on macOS)
fn get_colima_vm_ip() -> Option<String> {
    use std::process::Command;

    let output = Command::new("colima")
        .args(["list", "-j"])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    // colima list -j outputs one JSON object per line
    let json_str = String::from_utf8_lossy(&output.stdout);
    for line in json_str.lines() {
        if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(line) {
            if let Some(addr) = parsed["address"].as_str() {
                if !addr.is_empty() {
                    return Some(addr.to_string());
                }
            }
        }
    }
    None
}

fn dns_setup_linux(host: &str, port: u64, zone: &str) -> Result<()> {
    use std::process::Command;

    // Check if systemd-resolved is in use
    let resolved_running = Command::new("systemctl")
        .args(["is-active", "systemd-resolved"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim() == "active")
        .unwrap_or(false);

    if resolved_running {
        dns_setup_systemd_resolved(host, port, zone)
    } else {
        println!("{} systemd-resolved is not running", style(">>>").yellow());
        println!();
        println!("Please configure your DNS resolver manually.");
        println!("See: cata lab dns (for instructions)");
        Ok(())
    }
}

fn dns_setup_systemd_resolved(host: &str, port: u64, zone: &str) -> Result<()> {
    use std::process::Command;

    let conf_dir = "/etc/systemd/resolved.conf.d";
    let conf_file = format!("{}/{}.conf", conf_dir, zone.replace('.', "-"));

    // Check if already configured
    if std::path::Path::new(&conf_file).exists() {
        let content = fs::read_to_string(&conf_file).unwrap_or_default();
        if content.contains(&format!("DNS={}:{}", host, port)) {
            println!(
                "{} DNS resolver already configured at {}",
                style(">>>").green(),
                conf_file
            );
            return Ok(());
        }
    }

    let conf_content = format!("[Resolve]\nDNS={}:{}\nDomains=~{}\n", host, port, zone);

    println!("{} Creating {}...", style(">>>").cyan(), conf_file);

    // Create directory with sudo
    let mkdir_status = Command::new("sudo")
        .args(["mkdir", "-p", conf_dir])
        .status()
        .context("Failed to run sudo mkdir")?;

    if !mkdir_status.success() {
        bail!("Failed to create {}", conf_dir);
    }

    // Write config file with sudo tee
    let mut tee = Command::new("sudo")
        .args(["tee", &conf_file])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .spawn()
        .context("Failed to run sudo tee")?;

    if let Some(stdin) = tee.stdin.as_mut() {
        stdin.write_all(conf_content.as_bytes())?;
    }

    let tee_status = tee.wait()?;
    if !tee_status.success() {
        bail!("Failed to write {}", conf_file);
    }

    // Restart systemd-resolved
    println!("{} Restarting systemd-resolved...", style(">>>").cyan());

    let restart_status = Command::new("sudo")
        .args(["systemctl", "restart", "systemd-resolved"])
        .status()
        .context("Failed to restart systemd-resolved")?;

    if !restart_status.success() {
        println!(
            "{} Failed to restart systemd-resolved (may need manual restart)",
            style("Warning:").yellow()
        );
    }

    println!(
        "{} DNS resolver configured at {}",
        style(">>>").green(),
        conf_file
    );
    println!();
    println!("Test with: dig git.{}", zone);

    Ok(())
}

async fn dns_teardown(zone: &str, docker_subnet: &str) -> Result<()> {
    println!(
        "{} Removing DNS configuration for *.{}",
        style(">>>").cyan(),
        zone
    );

    if cfg!(target_os = "macos") {
        dns_teardown_macos(zone, docker_subnet)
    } else {
        dns_teardown_linux(zone)
    }
}

fn dns_teardown_macos(zone: &str, docker_subnet: &str) -> Result<()> {
    use std::process::Command;

    let resolver_file = format!("/etc/resolver/{}", zone);

    if std::path::Path::new(&resolver_file).exists() {
        println!("{} Removing {}...", style(">>>").cyan(), resolver_file);

        let rm_status = Command::new("sudo")
            .args(["rm", "-f", &resolver_file])
            .status()
            .context("Failed to run sudo rm")?;

        if !rm_status.success() {
            bail!("Failed to remove {}", resolver_file);
        }
    }

    // Remove Docker subnet route
    let _ = Command::new("sudo")
        .args(["route", "-n", "delete", "-net", docker_subnet])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();

    println!("{} DNS configuration removed", style(">>>").green());

    Ok(())
}

fn dns_teardown_linux(zone: &str) -> Result<()> {
    use std::process::Command;

    let conf_file = format!(
        "/etc/systemd/resolved.conf.d/{}.conf",
        zone.replace('.', "-")
    );

    if !std::path::Path::new(&conf_file).exists() {
        println!(
            "{} No resolver configuration found at {}",
            style(">>>").yellow(),
            conf_file
        );
        return Ok(());
    }

    println!("{} Removing {}...", style(">>>").cyan(), conf_file);

    let rm_status = Command::new("sudo")
        .args(["rm", "-f", &conf_file])
        .status()
        .context("Failed to run sudo rm")?;

    if !rm_status.success() {
        bail!("Failed to remove {}", conf_file);
    }

    // Restart systemd-resolved
    println!("{} Restarting systemd-resolved...", style(">>>").cyan());

    let restart_status = Command::new("sudo")
        .args(["systemctl", "restart", "systemd-resolved"])
        .status()
        .context("Failed to restart systemd-resolved")?;

    if !restart_status.success() {
        println!(
            "{} Failed to restart systemd-resolved (may need manual restart)",
            style("Warning:").yellow()
        );
    }

    println!("{} DNS configuration removed", style(">>>").green());

    Ok(())
}

async fn trust(
    ctx: &CataContext,
    name: &str,
    setup: bool,
    teardown: bool,
    export: bool,
) -> Result<()> {
    let lab = crate::nix::get_lab_config(ctx, name)?;
    let zone = lab
        .pointer("/dnsInfo/zone")
        .and_then(|v| v.as_str())
        .unwrap_or("lab.test");

    // Ensure cert exists
    ensure_ingress_cert(name, zone)?;

    let ca_cert = service_state_dir(name, "ingress").join("ca.crt");
    if !ca_cert.exists() {
        bail!("CA certificate not found. Run `cata lab init` first.");
    }

    if export {
        let content = fs::read_to_string(&ca_cert)?;
        print!("{}", content);
        return Ok(());
    }

    if teardown {
        return trust_teardown(name).await;
    }

    if setup {
        return trust_setup(name, &ca_cert).await;
    }

    // Default: show instructions
    println!("{} Lab TLS CA Trust", style("catallaxy").cyan().bold());
    println!();
    println!("CA certificate: {}", ca_cert.display());
    println!();
    println!("{}", style("Commands:").bold());
    println!("  cata lab trust --setup     # Add CA to browser trust store (no sudo)");
    println!("  cata lab trust --teardown  # Remove CA from browser trust store");
    println!("  cata lab trust --export    # Print CA cert PEM to stdout");
    println!();
    if cfg!(target_os = "macos") {
        println!("Trust store: macOS login keychain");
    } else {
        println!("Trust store: ~/.pki/nssdb (Chromium/Brave/Edge)");
        println!("Requires: libnss3-tools (certutil)");
    }
    println!();
    println!("Restart your browser after setup for changes to take effect.");
    println!("Trust is automatically removed on `cata lab down`.");

    Ok(())
}

async fn trust_setup(lab_name: &str, ca_cert: &std::path::Path) -> Result<()> {
    use std::process::Command;

    let cert_nickname = format!("catallaxy-{}", lab_name);

    if cfg!(target_os = "macos") {
        // macOS: add to user login keychain (no sudo)
        let home = std::env::var("HOME").unwrap_or_default();
        let keychain = format!("{home}/Library/Keychains/login.keychain-db");

        println!("{} Adding lab CA to login keychain...", style(">>>").cyan());

        let status = Command::new("security")
            .args(["add-trusted-cert", "-r", "trustRoot", "-k", &keychain])
            .arg(ca_cert)
            .status()
            .context("Failed to run security add-trusted-cert")?;

        if !status.success() {
            bail!("Failed to add CA to macOS login keychain");
        }
    } else {
        // Linux: add to NSS database for Chromium-based browsers (no sudo)
        let home = std::env::var("HOME").unwrap_or_default();
        let nss_dir = format!("{home}/.pki/nssdb");
        let nss_db = format!("sql:{nss_dir}");

        println!(
            "{} Adding lab CA to browser trust store (~/.pki/nssdb)...",
            style(">>>").cyan()
        );

        // Ensure NSS DB exists
        fs::create_dir_all(&nss_dir)?;
        let cert_db = format!("{nss_dir}/cert9.db");
        if !std::path::Path::new(&cert_db).exists() {
            let status = Command::new("certutil")
                .args(["-d", &nss_db, "-N", "--empty-password"])
                .status()
                .context("Failed to initialize NSS database. Install libnss3-tools.")?;
            if !status.success() {
                bail!("Failed to initialize NSS database");
            }
        }

        // Remove old cert if it exists (idempotent)
        let _ = Command::new("certutil")
            .args(["-d", &nss_db, "-D", "-n", &cert_nickname])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();

        // Add the CA cert
        let status = Command::new("certutil")
            .args(["-d", &nss_db, "-A", "-t", "C,,", "-n", &cert_nickname, "-i"])
            .arg(ca_cert)
            .status()
            .context("Failed to run certutil. Install libnss3-tools (apt) or nss-tools (dnf).")?;

        if !status.success() {
            bail!("Failed to add CA to NSS database");
        }
    }

    println!(
        "{} Lab CA trusted by browsers (restart browser to take effect)",
        style(">>>").green()
    );
    Ok(())
}

async fn trust_teardown(lab_name: &str) -> Result<()> {
    use std::process::Command;

    let cert_nickname = format!("catallaxy-{}", lab_name);

    if cfg!(target_os = "macos") {
        let home = std::env::var("HOME").unwrap_or_default();
        let keychain = format!("{home}/Library/Keychains/login.keychain-db");

        println!(
            "{} Removing lab CA from login keychain...",
            style(">>>").cyan()
        );

        let status = Command::new("security")
            .args([
                "delete-certificate",
                "-c",
                "Catallaxy Lab CA",
                "-k",
                &keychain,
            ])
            .status()
            .context("Failed to run security delete-certificate")?;

        if !status.success() {
            println!(
                "{} CA may not be in keychain (already removed?)",
                style(">>>").yellow()
            );
        }
    } else {
        let home = std::env::var("HOME").unwrap_or_default();
        let nss_db = format!("sql:{home}/.pki/nssdb");

        println!(
            "{} Removing lab CA from browser trust store...",
            style(">>>").cyan()
        );

        let status = Command::new("certutil")
            .args(["-d", &nss_db, "-D", "-n", &cert_nickname])
            .status();

        match status {
            Ok(s) if s.success() => {}
            _ => {
                println!(
                    "{} CA may not be in NSS database (already removed?)",
                    style(">>>").yellow()
                );
            }
        }
    }

    println!(
        "{} Lab CA removed from browser trust store",
        style(">>>").green()
    );
    Ok(())
}

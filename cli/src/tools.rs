//! External tool orchestration
//!
//! Wraps calls to talosctl, kubectl, kapp, helm, colima, etc.

use std::process::{Command, Stdio};

use anyhow::{Context, Result, bail};
use console::style;

use crate::config::Context as CataContext;

/// Check that a tool is available
pub fn check_tool(name: &str) -> Result<()> {
    which::which(name).with_context(|| format!("Tool not found: {name}"))?;
    Ok(())
}

/// Check all required tools are available
pub fn check_required_tools() -> Result<()> {
    let tools = ["kubectl", "helm", "nix"];
    for tool in tools {
        check_tool(tool)?;
    }
    if cfg!(target_os = "macos") {
        check_tool("colima")?;
    }
    Ok(())
}

/// Run a command and stream output
pub fn run_streaming(cmd: &mut Command, ctx: &CataContext) -> Result<()> {
    if ctx.verbose {
        eprintln!("{} {:?}", style("Running:").dim(), cmd);
    }

    let status = cmd
        .stdin(Stdio::null())
        .status()
        .context("Failed to execute command")?;

    if !status.success() {
        bail!("Command failed with status: {status}");
    }

    Ok(())
}

/// Run a command and capture output
pub fn run_capture(cmd: &mut Command, ctx: &CataContext) -> Result<String> {
    if ctx.verbose {
        eprintln!("{} {:?}", style("Running:").dim(), cmd);
    }

    let output = cmd
        .stdin(Stdio::null())
        .output()
        .context("Failed to execute command")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!("Command failed: {stderr}");
    }

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

/// Colima operations (macOS only)
pub mod colima {
    use super::*;

    /// Check if we're running on macOS
    pub fn is_macos() -> bool {
        cfg!(target_os = "macos")
    }

    /// Get the docker socket path for a colima profile
    pub fn docker_socket(profile: &str) -> String {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        format!("unix://{home}/.colima/{profile}/docker.sock")
    }

    /// Check if a colima profile is running
    pub fn profile_running(profile: &str) -> bool {
        // First check via colima status
        let status = Command::new("colima")
            .args(["status", "--profile", profile])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();

        if matches!(status, Ok(s) if s.success()) {
            return true;
        }

        // Fallback: check if the docker socket exists and is usable
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        let sock = format!("{home}/.colima/{profile}/docker.sock");
        std::path::Path::new(&sock).exists()
    }

    /// Start a colima profile with the given resources.
    /// If already running, this is a no-op.
    pub fn start(ctx: &CataContext, profile: &str, cpu: u64, memory: u64, disk: u64) -> Result<()> {
        // Double-check: if already running, skip
        if profile_running(profile) {
            println!(
                "{} Colima VM already running (profile: {profile})",
                style(">>>").green()
            );
            return Ok(());
        }

        println!(
            "{} Starting Colima VM (profile: {profile}, cpu: {cpu}, memory: {memory}G, disk: {disk}G)...",
            style(">>>").cyan()
        );

        let mut cmd = Command::new("colima");
        cmd.args([
            "start",
            "--profile",
            profile,
            "--cpu",
            &cpu.to_string(),
            "--memory",
            &memory.to_string(),
            "--disk",
            &disk.to_string(),
            "--runtime",
            "docker",
        ]);

        run_streaming(&mut cmd, ctx)?;

        println!("{} Colima VM ready", style(">>>").green());
        Ok(())
    }
}

/// Talosctl operations
pub mod talos {
    use super::*;

    /// Create a Talos cluster in Docker
    pub fn cluster_create(
        ctx: &CataContext,
        name: &str,
        _control_planes: u32,
        workers: u32,
        docker_host: Option<&str>,
    ) -> Result<()> {
        println!("{} Creating Talos cluster '{name}'...", style(">>>").cyan());

        let mut cmd = Command::new("talosctl");
        cmd.args([
            "cluster",
            "create",
            "docker",
            "--name",
            name,
            "--workers",
            &workers.to_string(),
        ]);

        if let Some(host) = docker_host {
            cmd.env("DOCKER_HOST", host);
        }

        run_streaming(&mut cmd, ctx)?;

        println!(
            "{} Cluster created. Kubeconfig merged into ~/.kube/config",
            style(">>>").green()
        );
        Ok(())
    }

    /// Destroy a Talos cluster
    pub fn cluster_destroy(ctx: &CataContext, name: &str, docker_host: Option<&str>) -> Result<()> {
        println!(
            "{} Destroying Talos cluster '{name}'...",
            style(">>>").cyan()
        );

        let mut cmd = Command::new("talosctl");
        cmd.args(["cluster", "destroy", "--name", name]);

        if let Some(host) = docker_host {
            cmd.env("DOCKER_HOST", host);
        }

        run_streaming(&mut cmd, ctx)?;

        println!("{} Cluster destroyed", style(">>>").green());
        Ok(())
    }

    /// Check if a cluster exists by looking for its state file
    pub fn cluster_exists(name: &str, _docker_host: Option<&str>) -> bool {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        let state_file = format!("{home}/.talos/clusters/{name}/state.yaml");
        std::path::Path::new(&state_file).exists()
    }

    /// Show cluster status
    pub fn cluster_show(ctx: &CataContext, name: &str, docker_host: Option<&str>) -> Result<()> {
        let mut cmd = Command::new("talosctl");
        cmd.args(["cluster", "show", "--name", name]);

        if let Some(host) = docker_host {
            cmd.env("DOCKER_HOST", host);
        }

        run_streaming(&mut cmd, ctx)
    }
}

/// k3d operations
pub mod k3d {
    use super::*;

    /// Create a k3d cluster
    pub fn cluster_create(
        ctx: &CataContext,
        name: &str,
        workers: u32,
        no_traefik: bool,
        no_service_lb: bool,
        no_flannel: bool,
        image: Option<&str>,
        docker_host: Option<&str>,
        registries_yaml: Option<&str>,
        service_cidr: Option<&str>,
        pod_cidr: Option<&str>,
        auto_deploy_manifests: &[(String, String)],
        ports: &[&str],
        network: Option<&str>,
    ) -> Result<()> {
        println!("{} Creating k3d cluster '{name}'...", style(">>>").cyan());

        let mut cmd = Command::new("k3d");
        cmd.args(["cluster", "create", name, "--agents", &workers.to_string()]);

        // Docker network (shared lab network for cross-cluster DNS)
        if let Some(net) = network {
            cmd.args(["--network", net]);
        }

        if no_traefik {
            cmd.args(["--k3s-arg", "--disable=traefik@server:*"]);
        }
        if no_service_lb {
            cmd.args(["--k3s-arg", "--disable=servicelb@server:*"]);
        }
        if no_flannel {
            cmd.args(["--k3s-arg", "--flannel-backend=none@server:*"]);
            cmd.args(["--k3s-arg", "--disable-network-policy@server:*"]);
        }

        // Service and pod CIDRs
        if let Some(cidr) = service_cidr {
            cmd.args(["--k3s-arg", &format!("--service-cidr={cidr}@server:*")]);
        }
        if let Some(cidr) = pod_cidr {
            cmd.args(["--k3s-arg", &format!("--cluster-cidr={cidr}@server:*")]);
        }

        // Mount auto-deploy manifests into k3s server manifests directory
        // k3s applies these at boot (used for pre-deploying CNI)
        // Nix store paths are read-only, so copy to a writable temp location
        let auto_deploy_dir = if !auto_deploy_manifests.is_empty() {
            let dir = std::env::temp_dir().join(format!("cata-autodeploy-{name}"));
            // Remove stale dir (previous copies are read-only from nix store)
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir)?;
            Some(dir)
        } else {
            None
        };
        for (manifest_name, manifest_path) in auto_deploy_manifests {
            let host_path = if let Some(ref dir) = auto_deploy_dir {
                let dest = dir.join(format!("{manifest_name}.yaml"));
                std::fs::copy(manifest_path, &dest).with_context(|| {
                    format!("Failed to copy auto-deploy manifest {manifest_path}")
                })?;
                dest.display().to_string()
            } else {
                manifest_path.clone()
            };
            cmd.args(["--volume",
                &format!("{host_path}:/var/lib/rancher/k3s/server/manifests/{manifest_name}.yaml@server:*")]);
        }

        // Port mappings (e.g. "8080:80@server:0")
        for port in ports {
            cmd.args(["-p", port]);
        }

        // Mount Docker socket for tools that need sibling container access.
        cmd.args([
            "--volume",
            "/var/run/docker.sock:/var/run/docker.sock@server:0",
        ]);

        // Mount registries.yaml for pull-through cache configuration
        if let Some(path) = registries_yaml {
            cmd.args([
                "--volume",
                &format!("{}:/etc/rancher/k3s/registries.yaml@server:*", path),
            ]);
        }

        if let Some(img) = image {
            cmd.args(["--image", img]);
        }
        if let Some(host) = docker_host {
            cmd.env("DOCKER_HOST", host);
        }

        run_streaming(&mut cmd, ctx)?;

        println!(
            "{} Cluster ready (context: k3d-{name})",
            style(">>>").green()
        );
        Ok(())
    }

    /// Destroy a k3d cluster
    pub fn cluster_destroy(ctx: &CataContext, name: &str, docker_host: Option<&str>) -> Result<()> {
        println!("{} Destroying k3d cluster '{name}'...", style(">>>").cyan());

        let mut cmd = Command::new("k3d");
        cmd.args(["cluster", "delete", name]);

        if let Some(host) = docker_host {
            cmd.env("DOCKER_HOST", host);
        }

        run_streaming(&mut cmd, ctx)?;

        println!("{} Cluster destroyed", style(">>>").green());
        Ok(())
    }

    /// Check if a k3d cluster exists
    pub fn cluster_exists(name: &str, docker_host: Option<&str>) -> bool {
        let mut cmd = Command::new("k3d");
        cmd.args(["cluster", "get", name]);
        cmd.stdout(Stdio::null());
        cmd.stderr(Stdio::null());

        if let Some(host) = docker_host {
            cmd.env("DOCKER_HOST", host);
        }

        let status = cmd.status();
        matches!(status, Ok(s) if s.success())
    }

    /// Show cluster info
    pub fn cluster_show(ctx: &CataContext, name: &str, docker_host: Option<&str>) -> Result<()> {
        let mut cmd = Command::new("k3d");
        cmd.args(["cluster", "get", name]);

        if let Some(host) = docker_host {
            cmd.env("DOCKER_HOST", host);
        }

        run_streaming(&mut cmd, ctx)
    }
}

/// Kubectl operations
pub mod kube {
    use super::*;
    use std::path::PathBuf;

    /// Delete a kubeconfig context from ~/.kube/config
    pub fn delete_kubeconfig_context(ctx: &CataContext, context_name: &str) -> Result<()> {
        let mut cmd = Command::new("kubectl");
        cmd.args(["config", "delete-context", context_name]);
        // Ignore errors if context doesn't exist
        let _ = run_capture(&mut cmd, ctx);
        Ok(())
    }

    /// Delete a kubeconfig cluster entry from ~/.kube/config
    pub fn delete_kubeconfig_cluster(ctx: &CataContext, cluster_name: &str) -> Result<()> {
        let mut cmd = Command::new("kubectl");
        cmd.args(["config", "delete-cluster", cluster_name]);
        // Ignore errors if cluster doesn't exist
        let _ = run_capture(&mut cmd, ctx);
        Ok(())
    }

    /// Delete a kubeconfig user entry from ~/.kube/config
    pub fn delete_kubeconfig_user(ctx: &CataContext, user_name: &str) -> Result<()> {
        let mut cmd = Command::new("kubectl");
        cmd.args(["config", "delete-user", user_name]);
        // Ignore errors if user doesn't exist
        let _ = run_capture(&mut cmd, ctx);
        Ok(())
    }

    /// Check if the API server is reachable
    pub fn api_reachable(context: &str) -> bool {
        let output = Command::new("kubectl")
            .args(["--context", context, "version", "--request-timeout=2s"])
            .output();

        matches!(output, Ok(o) if o.status.success())
    }

    /// Wait for a CRD to be established, retrying until it appears.
    /// CRDs created by operators may not exist immediately.
    pub fn wait_crd_established(
        _ctx: &CataContext,
        context: &str,
        crd_name: &str,
        timeout: &str,
    ) -> Result<()> {
        use std::time::{Duration, Instant};

        let timeout_duration = parse_timeout(timeout);
        let start = Instant::now();

        // Retry loop: wait for the CRD to appear, then wait for Established
        loop {
            let result = Command::new("kubectl")
                .args([
                    "--context",
                    context,
                    "wait",
                    "--for=condition=Established",
                    &format!("crd/{crd_name}"),
                    "--timeout=10s",
                ])
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .output();

            match result {
                Ok(output) if output.status.success() => {
                    println!(
                        "customresourcedefinition.apiextensions.k8s.io/{crd_name} condition met"
                    );
                    return Ok(());
                }
                _ => {
                    if start.elapsed() > timeout_duration {
                        bail!("Timed out waiting for CRD: {crd_name}");
                    }
                    std::thread::sleep(Duration::from_secs(5));
                }
            }
        }
    }

    fn parse_timeout(timeout: &str) -> std::time::Duration {
        let s = timeout.trim_end_matches('m').trim_end_matches('s');
        if timeout.ends_with('m') {
            std::time::Duration::from_secs(s.parse::<u64>().unwrap_or(10) * 60)
        } else {
            std::time::Duration::from_secs(s.parse::<u64>().unwrap_or(600))
        }
    }

    /// Get kubeconfig for a CAPI-managed cluster from its secret.
    /// CAPI stores kubeconfigs in secrets named `<cluster>-kubeconfig`.
    /// This is a kubectl-based alternative that doesn't require clusterctl.
    pub fn get_capi_kubeconfig(
        kube_context: &str,
        cluster_name: &str,
        namespace: &str,
    ) -> Result<String> {
        let secret_name = format!("{cluster_name}-kubeconfig");

        // Get the base64-encoded kubeconfig from the secret
        let output = Command::new("kubectl")
            .args([
                "--context",
                kube_context,
                "get",
                "secret",
                &secret_name,
                "-n",
                namespace,
                "-o",
                "jsonpath={.data.value}",
            ])
            .output()
            .context("Failed to run kubectl")?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            bail!("Failed to get kubeconfig secret: {stderr}");
        }

        let encoded = String::from_utf8_lossy(&output.stdout);
        if encoded.is_empty() {
            bail!("Kubeconfig secret '{secret_name}' is empty or not found");
        }

        // Decode base64
        use std::process::Stdio;
        let mut decode = Command::new("base64")
            .args(["--decode"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .context("Failed to spawn base64 decode")?;

        if let Some(stdin) = decode.stdin.as_mut() {
            use std::io::Write;
            stdin.write_all(encoded.as_bytes())?;
        }

        let decode_output = decode.wait_with_output()?;
        if !decode_output.status.success() {
            bail!("Failed to decode kubeconfig");
        }

        Ok(String::from_utf8_lossy(&decode_output.stdout).to_string())
    }

    /// Merge a kubeconfig file into the default kubeconfig (~/.kube/config)
    pub fn merge_kubeconfig(kubeconfig_path: &PathBuf, context_name: &str) -> Result<()> {
        println!(
            "{} Merging kubeconfig for context '{context_name}'...",
            style(">>>").cyan()
        );

        let default_kubeconfig =
            PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string()))
                .join(".kube")
                .join("config");

        // Use KUBECONFIG env var to merge
        let kubeconfig_env = format!(
            "{}:{}",
            kubeconfig_path.display(),
            default_kubeconfig.display()
        );

        let output = Command::new("kubectl")
            .env("KUBECONFIG", &kubeconfig_env)
            .args(["config", "view", "--flatten"])
            .output()?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            bail!("Failed to merge kubeconfig: {stderr}");
        }

        // Write merged config
        std::fs::write(&default_kubeconfig, &output.stdout)?;

        println!("{} Kubeconfig merged", style(">>>").green());

        Ok(())
    }
}

/// Kapp operations
pub mod kapp {
    use super::*;

    /// Deploy a manifest directory via kapp.
    ///
    /// kapp's --namespace flag is only for its own state-tracking ConfigMap,
    /// not for the deployed resources (those carry their own namespace).
    pub fn deploy(
        ctx: &CataContext,
        kube_context: &str,
        app_name: &str,
        manifests_dir: &str,
        timeout: &str,
    ) -> Result<()> {
        // Prefix app name to avoid collision with Helm chart resources
        let prefixed_app_name = format!("cata-{}", app_name);

        let mut cmd = Command::new("kapp");
        cmd.args([
            "deploy",
            "--kubeconfig-context",
            kube_context,
            "--app",
            &prefixed_app_name,
            "--namespace",
            "default",
            "--file",
            manifests_dir,
            "--yes",
            "--wait",
            "--wait-check-interval",
            "5s",
            "--wait-timeout",
            timeout,
        ]);

        run_streaming(&mut cmd, ctx)
    }
}

/// Docker container operations
pub mod docker {
    use super::*;

    /// Check if a named container is running
    pub fn container_running(name: &str) -> bool {
        let output = Command::new("docker")
            .args(["inspect", "-f", "{{.State.Running}}", name])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .output();

        match output {
            Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim() == "true",
            _ => false,
        }
    }

    /// Check if a named container exists (running or stopped)
    pub fn container_exists(name: &str) -> bool {
        Command::new("docker")
            .args(["inspect", name])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map_or(false, |s| s.success())
    }

    /// Run a container in detached mode
    pub fn run_container(
        ctx: &CataContext,
        name: &str,
        image: &str,
        ports: &[&str],
        volume_mounts: &[(&str, &str)],
        command: &[&str],
    ) -> Result<()> {
        // Remove stale container if it exists but isn't running
        if container_exists(name) && !container_running(name) {
            let _ = Command::new("docker")
                .args(["rm", name])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
        }

        let mut cmd = Command::new("docker");
        cmd.args(["run", "-d", "--name", name, "--restart", "unless-stopped"]);

        for port in ports {
            cmd.args(["-p", port]);
        }

        for (host_path, container_path) in volume_mounts {
            cmd.args(["-v", &format!("{host_path}:{container_path}")]);
        }

        cmd.arg(image);
        cmd.args(command);
        run_streaming(&mut cmd, ctx)
    }

    /// Get a container's IP address on the default bridge network
    pub fn get_container_ip(container: &str) -> Option<String> {
        let output = Command::new("docker")
            .args(["inspect", "-f", "{{.NetworkSettings.IPAddress}}", container])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .output()
            .ok()?;

        if output.status.success() {
            let ip = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !ip.is_empty() {
                return Some(ip);
            }
        }
        None
    }

    /// Run a container with extended options (link, networks, dns, command, networkMode, capAdd)
    pub fn run_container_extended(
        ctx: &CataContext,
        name: &str,
        image: &str,
        ports: &[&str],
        volume_mounts: &[(&str, &str)],
        link: Option<&str>,
        networks: &[&str],
        dns_ips: &[String],
        command: &[&str],
        network_mode: Option<&str>,
        cap_add: &[&str],
        network_ips: &std::collections::HashMap<String, String>,
    ) -> Result<()> {
        // Remove stale container if it exists but isn't running
        if container_exists(name) && !container_running(name) {
            let _ = Command::new("docker")
                .args(["rm", name])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
        }

        let mut cmd = Command::new("docker");
        cmd.args(["run", "-d", "--name", name, "--restart", "unless-stopped"]);

        // Network mode (e.g., "host") or use the first declared network as primary
        if let Some(mode) = network_mode {
            cmd.args(["--network", mode]);
        } else if let Some(first_net) = networks.first() {
            cmd.args(["--network", first_net]);
        }

        // Capabilities
        for cap in cap_add {
            cmd.args(["--cap-add", cap]);
        }

        for port in ports {
            cmd.args(["-p", port]);
        }

        for (host_path, container_path) in volume_mounts {
            cmd.args(["-v", &format!("{host_path}:{container_path}")]);
        }

        // Custom DNS servers
        for dns_ip in dns_ips {
            cmd.args(["--dns", dns_ip]);
        }

        // Link to another container for DNS resolution
        if let Some(link_container) = link {
            cmd.args(["--link", link_container]);
        }

        cmd.arg(image);
        cmd.args(command);
        run_streaming(&mut cmd, ctx)?;

        // Connect to additional networks after container starts
        for network in networks {
            // Check for static IP config for this network
            if let Some(ip) = network_ips.get(*network) {
                let _ = Command::new("docker")
                    .args(["network", "connect", "--ip", ip, network, name])
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status();
            } else {
                let _ = Command::new("docker")
                    .args(["network", "connect", network, name])
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status();
            }
        }

        Ok(())
    }

    /// Stop and remove a container
    pub fn stop_container(ctx: &CataContext, name: &str) -> Result<()> {
        if container_running(name) {
            let mut cmd = Command::new("docker");
            cmd.args(["stop", name]);
            run_streaming(&mut cmd, ctx)?;
        }

        if container_exists(name) {
            let mut cmd = Command::new("docker");
            cmd.args(["rm", name]);
            run_streaming(&mut cmd, ctx)?;
        }

        Ok(())
    }
}

/// Velero operations (backup and restore)
pub mod velero {
    use super::*;

    /// Create a backup
    pub fn create_backup(
        ctx: &CataContext,
        kube_context: &str,
        backup_name: &str,
        namespaces: Option<&[&str]>,
        exclude_namespaces: Option<&[&str]>,
        include_cluster_resources: bool,
        wait: bool,
    ) -> Result<()> {
        println!("{} Creating backup '{backup_name}'...", style(">>>").cyan());

        let mut cmd = Command::new("velero");
        cmd.args(["backup", "create", backup_name]);
        cmd.args(["--kubecontext", kube_context]);

        if let Some(ns) = namespaces {
            if !ns.is_empty() {
                cmd.args(["--include-namespaces", &ns.join(",")]);
            }
        }

        if let Some(ns) = exclude_namespaces {
            if !ns.is_empty() {
                cmd.args(["--exclude-namespaces", &ns.join(",")]);
            }
        }

        if include_cluster_resources {
            cmd.arg("--include-cluster-resources=true");
        }

        if wait {
            cmd.arg("--wait");
        }

        run_streaming(&mut cmd, ctx)?;

        println!("{} Backup '{backup_name}' created", style(">>>").green());
        Ok(())
    }

    /// Restore from a backup
    pub fn restore(
        ctx: &CataContext,
        kube_context: &str,
        backup_name: &str,
        restore_name: Option<&str>,
        namespaces: Option<&[&str]>,
        wait: bool,
    ) -> Result<()> {
        let restore_name = restore_name.unwrap_or(backup_name);
        println!(
            "{} Restoring from backup '{backup_name}'...",
            style(">>>").cyan()
        );

        let mut cmd = Command::new("velero");
        cmd.args(["restore", "create", restore_name]);
        cmd.args(["--from-backup", backup_name]);
        cmd.args(["--kubecontext", kube_context]);

        if let Some(ns) = namespaces {
            if !ns.is_empty() {
                cmd.args(["--include-namespaces", &ns.join(",")]);
            }
        }

        if wait {
            cmd.arg("--wait");
        }

        run_streaming(&mut cmd, ctx)?;

        println!(
            "{} Restore from '{backup_name}' completed",
            style(">>>").green()
        );
        Ok(())
    }

    /// List backups
    pub fn list_backups(ctx: &CataContext, kube_context: &str) -> Result<String> {
        let mut cmd = Command::new("velero");
        cmd.args(["backup", "get"]);
        cmd.args(["--kubecontext", kube_context]);
        run_capture(&mut cmd, ctx)
    }

    /// List restores
    pub fn list_restores(ctx: &CataContext, kube_context: &str) -> Result<String> {
        let mut cmd = Command::new("velero");
        cmd.args(["restore", "get"]);
        cmd.args(["--kubecontext", kube_context]);
        run_capture(&mut cmd, ctx)
    }

    /// Get backup details
    pub fn describe_backup(
        ctx: &CataContext,
        kube_context: &str,
        backup_name: &str,
    ) -> Result<String> {
        let mut cmd = Command::new("velero");
        cmd.args(["backup", "describe", backup_name]);
        cmd.args(["--kubecontext", kube_context]);
        cmd.arg("--details");
        run_capture(&mut cmd, ctx)
    }

    /// Get backup logs
    pub fn backup_logs(ctx: &CataContext, kube_context: &str, backup_name: &str) -> Result<String> {
        let mut cmd = Command::new("velero");
        cmd.args(["backup", "logs", backup_name]);
        cmd.args(["--kubecontext", kube_context]);
        run_capture(&mut cmd, ctx)
    }

    /// Delete a backup
    pub fn delete_backup(ctx: &CataContext, kube_context: &str, backup_name: &str) -> Result<()> {
        println!("{} Deleting backup '{backup_name}'...", style(">>>").cyan());

        let mut cmd = Command::new("velero");
        cmd.args(["backup", "delete", backup_name]);
        cmd.args(["--kubecontext", kube_context]);
        cmd.arg("--confirm");

        run_streaming(&mut cmd, ctx)?;

        println!("{} Backup '{backup_name}' deleted", style(">>>").green());
        Ok(())
    }

    /// List schedules
    pub fn list_schedules(ctx: &CataContext, kube_context: &str) -> Result<String> {
        let mut cmd = Command::new("velero");
        cmd.args(["schedule", "get"]);
        cmd.args(["--kubecontext", kube_context]);
        run_capture(&mut cmd, ctx)
    }

    /// Trigger a schedule manually
    pub fn trigger_schedule(
        ctx: &CataContext,
        kube_context: &str,
        schedule_name: &str,
    ) -> Result<()> {
        println!(
            "{} Triggering schedule '{schedule_name}'...",
            style(">>>").cyan()
        );

        let mut cmd = Command::new("velero");
        cmd.args(["backup", "create", "--from-schedule", schedule_name]);
        cmd.args(["--kubecontext", kube_context]);

        run_streaming(&mut cmd, ctx)?;

        println!(
            "{} Schedule '{schedule_name}' triggered",
            style(">>>").green()
        );
        Ok(())
    }

    /// Check if velero is installed and ready
    pub fn is_ready(kube_context: &str) -> bool {
        let output = Command::new("kubectl")
            .args([
                "--context",
                kube_context,
                "get",
                "deployment",
                "velero",
                "-n",
                "velero",
                "-o",
                "jsonpath={.status.readyReplicas}",
            ])
            .output();

        match output {
            Ok(o) if o.status.success() => {
                let replicas = String::from_utf8_lossy(&o.stdout);
                replicas.trim().parse::<i32>().unwrap_or(0) > 0
            }
            _ => false,
        }
    }
}

/// clusterctl operations (Cluster API CLI)
pub mod clusterctl {
    use super::*;

    /// Provider specification for clusterctl init
    pub struct ProviderSpec {
        pub bootstrap: Vec<String>,
        pub control_plane: Vec<String>,
        pub infrastructure: Vec<String>,
    }

    /// Initialize CAPI on a cluster
    pub fn init(ctx: &CataContext, kube_context: &str, providers: &ProviderSpec) -> Result<()> {
        println!("{} Initializing Cluster API...", style(">>>").cyan());

        let mut cmd = Command::new("clusterctl");
        cmd.env("KUBECONFIG_CONTEXT", kube_context);
        cmd.args(["init"]);

        for bp in &providers.bootstrap {
            cmd.args(["--bootstrap", bp]);
        }
        for cp in &providers.control_plane {
            cmd.args(["--control-plane", cp]);
        }
        for ip in &providers.infrastructure {
            cmd.args(["--infrastructure", ip]);
        }

        run_streaming(&mut cmd, ctx)?;

        println!("{} Cluster API initialized", style(">>>").green());
        Ok(())
    }

    /// Move CAPI resources from one cluster to another (pivot)
    pub fn move_resources(
        ctx: &CataContext,
        from_context: &str,
        to_context: &str,
        namespace: &str,
    ) -> Result<()> {
        println!(
            "{} Moving CAPI resources from {} to {}...",
            style(">>>").cyan(),
            from_context,
            to_context
        );

        let mut cmd = Command::new("clusterctl");
        cmd.args([
            "move",
            "--kubeconfig-context",
            from_context,
            "--to-kubeconfig-context",
            to_context,
            "--namespace",
            namespace,
        ]);

        run_streaming(&mut cmd, ctx)?;

        println!("{} CAPI resources moved successfully", style(">>>").green());
        Ok(())
    }

    /// Get kubeconfig for a CAPI-managed cluster
    pub fn get_kubeconfig(
        ctx: &CataContext,
        kube_context: &str,
        cluster_name: &str,
        namespace: &str,
    ) -> Result<String> {
        println!(
            "{} Getting kubeconfig for cluster '{cluster_name}'...",
            style(">>>").cyan()
        );

        let mut cmd = Command::new("clusterctl");
        cmd.args([
            "get",
            "kubeconfig",
            cluster_name,
            "--kubeconfig-context",
            kube_context,
            "--namespace",
            namespace,
        ]);

        run_capture(&mut cmd, ctx)
    }

    /// Wait for a cluster to be ready
    pub fn wait_cluster_ready(
        ctx: &CataContext,
        kube_context: &str,
        cluster_name: &str,
        namespace: &str,
        timeout: &str,
    ) -> Result<()> {
        println!(
            "{} Waiting for cluster '{}' to be ready...",
            style(">>>").cyan(),
            cluster_name
        );

        // Wait for the Cluster resource to have Ready=True condition
        let mut cmd = Command::new("kubectl");
        cmd.args([
            "--context",
            kube_context,
            "wait",
            "--for=condition=Ready",
            &format!("cluster/{cluster_name}"),
            "-n",
            namespace,
            &format!("--timeout={timeout}"),
        ]);

        run_streaming(&mut cmd, ctx)?;

        println!(
            "{} Cluster '{}' is ready",
            style(">>>").green(),
            cluster_name
        );
        Ok(())
    }

    /// Wait for control plane to be initialized
    pub fn wait_control_plane_initialized(
        ctx: &CataContext,
        kube_context: &str,
        cluster_name: &str,
        namespace: &str,
        timeout: &str,
    ) -> Result<()> {
        println!(
            "{} Waiting for control plane to be initialized...",
            style(">>>").cyan()
        );

        let mut cmd = Command::new("kubectl");
        cmd.args([
            "--context",
            kube_context,
            "wait",
            "--for=condition=ControlPlaneInitialized",
            &format!("cluster/{cluster_name}"),
            "-n",
            namespace,
            &format!("--timeout={timeout}"),
        ]);

        run_streaming(&mut cmd, ctx)?;

        println!("{} Control plane initialized", style(">>>").green());
        Ok(())
    }

    /// Non-blocking check if a CAPI cluster is ready.
    /// Returns true if the cluster's Ready condition is "True".
    pub fn is_cluster_ready(kube_context: &str, cluster_name: &str, namespace: &str) -> bool {
        let output = Command::new("kubectl")
            .args([
                "--context",
                kube_context,
                "get",
                "cluster",
                cluster_name,
                "-n",
                namespace,
                "-o",
                "jsonpath={.status.conditions[?(@.type==\"Ready\")].status}",
            ])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .output();

        match output {
            Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim() == "True",
            _ => false,
        }
    }
}

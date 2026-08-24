use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use console::style;

use crate::config::Context as CataContext;
use crate::domain::{ClusterSpec, ProvisionerKind};
use crate::io;

pub fn provisioner_cluster_name(spec: &ClusterSpec) -> &str {
    match spec.provisioner {
        ProvisionerKind::K3d => &spec.provisioner_config.k3d.cluster_name,
        ProvisionerKind::Talos => &spec.provisioner_config.talos.cluster_name,
        ProvisionerKind::Crossplane | ProvisionerKind::External => "",
    }
}

pub fn resolve_docker_host(_ctx: &CataContext, spec: &ClusterSpec) -> Result<Option<String>> {
    if !io::colima::is_macos() {
        return Ok(None);
    }

    let colima = &spec.provisioner_config.docker.colima;
    if !colima.enable {
        return Ok(None);
    }

    if io::colima::profile_running(&colima.profile) {
        println!(
            "{} Colima VM already running (profile: {})",
            style(">>>").green(),
            colima.profile
        );
    } else {
        io::colima::start(&colima.profile, colima.cpu, colima.memory, colima.disk)?;
    }

    Ok(Some(io::colima::docker_socket(&colima.profile)))
}

fn run_pre_provision_hooks(name: &str, spec: &ClusterSpec) -> Result<()> {
    for hook in &spec.lifecycle.pre_provision {
        if hook.bin.is_empty() {
            continue;
        }

        println!("{} [{name}] {}...", style(">>>").cyan(), hook.description);

        let status = io::hook::run(&hook.bin, &[], None).map_err(|e| {
            anyhow::anyhow!(
                "failed to exec preProvision hook `{}` for cluster `{name}`: {e}",
                hook.bin
            )
        })?;

        if !status.success() {
            bail!(
                "preProvision hook `{}` for cluster `{name}` failed \
                 (exit {}). See message above; the hook's stderr explains the \
                 fix.",
                hook.name,
                status.code().unwrap_or(-1)
            );
        }
    }

    Ok(())
}

pub fn provision_cluster_with_registry(
    ctx: &CataContext,
    name: &str,
    spec: &ClusterSpec,
    registries_yaml: Option<&std::path::Path>,
    lab_package: Option<&str>,
) -> Result<()> {
    let cluster_name = provisioner_cluster_name(spec).to_string();

    run_pre_provision_hooks(name, spec)?;

    match spec.provisioner {
        ProvisionerKind::K3d => {
            provision_k3d(ctx, name, &cluster_name, spec, registries_yaml, lab_package)?;
        }
        ProvisionerKind::Talos => {
            let docker_host = resolve_docker_host(ctx, spec)?;
            if io::talos::cluster_exists(&cluster_name, docker_host.as_deref()) {
                // Existing is not the same as matching. `cluster_create` below
                // reads controlPlanes and workers, so raising either used to
                // change the declaration and nothing else, under a green run.
                match converge_existing_cluster(
                    name,
                    spec,
                    docker_host.as_deref(),
                    ctx.may_recreate(name),
                )? {
                    Convergence::Unchanged => return Ok(()),
                    Convergence::MustRecreate => {
                        io::talos::cluster_destroy(&cluster_name, docker_host.as_deref())?;
                    }
                }
            }

            io::talos::cluster_create(io::talos::ClusterCreate {
                name: &cluster_name,
                workers: spec.kubernetes.workers,
                talos: &spec.provisioner_config.talos,
                docker_host: docker_host.as_deref(),
            })?;

            // talosctl returns as soon as it has started the containers, so
            // without this the run marches on to a deploy against an API that
            // is not up. The k3d path has always waited here.
            wait_until_answering(
                &spec.kube_context,
                &spec.provisioner_config.docker.wait_timeout,
            )?;

            crate::host::state::write_cluster_shape(
                &spec.lab_name,
                name,
                &crate::domain::cluster_shape::ClusterShape::of(spec),
            )?;
        }
        ProvisionerKind::Crossplane => {
            // Nothing to do here, and that is the whole answer: the cluster is
            // a Cluster CR applied with the rest of the manifests, so its
            // declaration converges when Crossplane reconciles it rather than
            // through a shape comparison catallaxy performs.
            println!(
                "{} Cluster '{name}' is declared as a Crossplane resource; \
                 the manifest apply is what converges it",
                style(">>>").cyan()
            );
        }
        ProvisionerKind::External => {
            println!(
                "{} Cluster '{name}' is external, so the lab declares nothing \
                 about how it is built and changes to it are not catallaxy's to make",
                style(">>>").cyan()
            );
        }
    }

    Ok(())
}

pub fn stop_cluster(ctx: &CataContext, name: &str, spec: &ClusterSpec) -> Result<()> {
    let cluster_name = provisioner_cluster_name(spec).to_string();

    match spec.provisioner {
        ProvisionerKind::K3d => {
            let docker_host = resolve_docker_host(ctx, spec)?;
            if !io::k3d::cluster_exists(&cluster_name, docker_host.as_deref()) {
                println!("{} Cluster '{name}' is not running", style(">>>").green());
                return Ok(());
            }
            io::k3d::cluster_stop(&cluster_name, docker_host.as_deref())?;
        }
        ProvisionerKind::External | ProvisionerKind::Crossplane => {
            println!(
                "  {} cluster '{name}', nothing to stop locally",
                spec.provider
            );
        }
        ProvisionerKind::Talos => {
            println!("  Cluster '{name}' (talos): stop not supported, skipping");
        }
    }

    Ok(())
}

pub fn deprovision_cluster(ctx: &CataContext, name: &str, spec: &ClusterSpec) -> Result<()> {
    let cluster_name = provisioner_cluster_name(spec).to_string();

    match spec.provisioner {
        ProvisionerKind::K3d => {
            let docker_host = resolve_docker_host(ctx, spec)?;
            if !io::k3d::cluster_exists(&cluster_name, docker_host.as_deref()) {
                println!("{} Cluster '{name}' is not running", style(">>>").green());
                return Ok(());
            }
            io::k3d::cluster_destroy(&cluster_name, docker_host.as_deref())?;
        }
        ProvisionerKind::Talos => {
            let docker_host = resolve_docker_host(ctx, spec)?;
            if !io::talos::cluster_exists(&cluster_name, docker_host.as_deref()) {
                println!("{} Cluster '{name}' is not running", style(">>>").green());
                return Ok(());
            }
            io::talos::cluster_destroy(&cluster_name, docker_host.as_deref())?;
        }
        ProvisionerKind::Crossplane => {
            println!(
                "{} Crossplane clusters are deprovisioned via CAPI on the management cluster",
                style(">>>").cyan()
            );
        }
        ProvisionerKind::External => {
            println!("  External clusters cannot be deleted via cata.");
        }
    }

    Ok(())
}

fn provision_k3d(
    ctx: &CataContext,
    name: &str,
    cluster_name: &str,
    spec: &ClusterSpec,
    registries_yaml: Option<&std::path::Path>,
    lab_package: Option<&str>,
) -> Result<()> {
    let docker_host = resolve_docker_host(ctx, spec)?;
    if io::k3d::cluster_exists(cluster_name, docker_host.as_deref()) {
        io::k3d::kubeconfig_merge(cluster_name, docker_host.as_deref())?;
        match converge_existing_cluster(name, spec, docker_host.as_deref(), ctx.may_recreate(name))?
        {
            Convergence::Unchanged => return Ok(()),
            Convergence::MustRecreate => {
                io::k3d::cluster_destroy(cluster_name, docker_host.as_deref())?;
            }
        }
    }

    let k3d = &spec.provisioner_config.k3d;
    let auto_deploy = resolve_auto_deploy(ctx, name, spec, lab_package);
    let port_refs: Vec<&str> = k3d.ports.iter().map(String::as_str).collect();

    let lab_name = ctx.resolve_lab_name(None)?;
    let state_dir = crate::host::state::lab_state_dir(&lab_name);
    let extra_volumes: Vec<(String, String)> = k3d
        .extra_volumes
        .iter()
        .map(|v| {
            (
                resolve_placeholders(&v.host_path, &state_dir, name),
                v.container_path.clone(),
            )
        })
        .collect();
    refuse_missing_mounts(name, &extra_volumes)?;

    let registries_yaml_str = registries_yaml.map(|p| p.to_string_lossy().to_string());
    let registry_dir = registries_yaml.and_then(|p| p.parent().map(|d| d.to_path_buf()));
    let certs_d_str = registry_dir
        .as_ref()
        .map(|d| d.join("certs.d"))
        .filter(|p| p.exists())
        .map(|p| p.to_string_lossy().to_string());
    let resolv_conf_str = registry_dir
        .as_ref()
        .map(|d| d.join("lab-resolv.conf"))
        .filter(|p| p.exists())
        .map(|p| p.to_string_lossy().to_string());

    io::k3d::cluster_create(io::k3d::ClusterCreate {
        name: cluster_name,
        workers: spec.kubernetes.workers,
        no_traefik: k3d.no_traefik,
        no_service_lb: k3d.no_service_lb,
        no_flannel: k3d.no_flannel,
        no_local_storage: k3d.no_local_storage,
        image: k3d.image.as_deref(),
        docker_host: docker_host.as_deref(),
        registries_yaml: registries_yaml_str.as_deref(),
        certs_d: certs_d_str.as_deref(),
        resolv_conf: resolv_conf_str.as_deref(),
        service_cidr: Some(spec.network.service_subnet.as_str()),
        pod_cidr: Some(spec.network.pod_subnet.as_str()),
        auto_deploy_manifests: &auto_deploy,
        ports: &port_refs,
        network: k3d.network.as_deref(),
        extra_api_server_args: &k3d.extra_api_server_args,
        extra_volumes: &extra_volumes,
    })?;

    // Explicitly, on this path too. Creation used to write the operator's
    // default kubeconfig by k3d's own default, so the only merge cata asked
    // for was on the already-exists path; turning that default off left a
    // fresh cluster with no entry anywhere and nothing to wait on.
    io::k3d::kubeconfig_merge(cluster_name, docker_host.as_deref())?;

    wait_until_answering(
        &spec.kube_context,
        &spec.provisioner_config.docker.wait_timeout,
    )?;

    crate::host::state::write_cluster_shape(
        &spec.lab_name,
        name,
        &crate::domain::cluster_shape::ClusterShape::of(spec),
    )?;

    Ok(())
}

/// Whether the caller still has to build the cluster.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Convergence {
    Unchanged,
    MustRecreate,
}

/// Bring an existing cluster into line with the declaration, or say why it
/// cannot be.
///
/// The comparison is against the shape the cluster was built from, not against
/// the live cluster: most of these fields cannot be read back without parsing
/// k3d internals, and a check that silently cannot see a field is the bug this
/// exists to fix.
///
/// Adding workers is done here. Everything else is baked into node containers
/// at creation, so the only convergence is recreation, which `--recreate`
/// performs and a bare `lab up` refuses.
fn converge_existing_cluster(
    name: &str,
    spec: &ClusterSpec,
    docker_host: Option<&str>,
    recreate: bool,
) -> Result<Convergence> {
    use crate::domain::cluster_shape::{ClusterShape, compare_shapes, describe};

    let declared = ClusterShape::of(spec);
    let recorded = match crate::host::state::read_cluster_shape(&spec.lab_name, name) {
        Some(recorded) => recorded,
        None => adopt_existing_cluster(name, spec, &declared)?,
    };

    let report = compare_shapes(&declared, &recorded);

    if report.is_clean() {
        println!(
            "{} Cluster '{name}' is already running and matches the lab",
            style(">>>").green()
        );
        report_out_of_band_drift(name, spec);
        return Ok(Convergence::Unchanged);
    }

    // Growing in place is a k3d capability, not a general one. Talos in Docker
    // has no equivalent of `k3d node create`, so for anything else a worker
    // count that moved is handled like every other field: refuse, and say what
    // would satisfy it.
    if let Some(to_add) = report
        .workers_to_add()
        .filter(|_| matches!(spec.provisioner, crate::domain::ProvisionerKind::K3d))
    {
        println!(
            "{} Cluster '{name}' is short {to_add} worker(s); adding them",
            style(">>>").cyan()
        );
        let existing = io::k3d::node_names(&spec.provisioner_config.k3d.cluster_name, docker_host)
            .len()
            .max(1);
        io::k3d::add_agents(
            &spec.provisioner_config.k3d.cluster_name,
            to_add,
            existing,
            docker_host,
        )?;
        crate::host::state::write_cluster_shape(&spec.lab_name, name, &declared)?;
        return Ok(Convergence::Unchanged);
    }

    if report.is_convergeable_in_place()
        && matches!(spec.provisioner, crate::domain::ProvisionerKind::K3d)
    {
        converge_k3d_in_place(name, spec, &report, &recorded, docker_host)?;
        // Recorded only after the cluster agrees. Writing the declaration
        // because convergence *ran* is how a node replaced with an unchanged
        // image produced a record claiming the version had moved, and a drift
        // check that read clean from then on.
        confirm_converged(name, spec, &declared)?;
        crate::host::state::write_cluster_shape(&spec.lab_name, name, &declared)?;
        return Ok(Convergence::Unchanged);
    }

    if recreate {
        println!("{}", describe(name, &report));
        println!(
            "{} --recreate given, so '{name}' will be destroyed and rebuilt",
            style("Warning:").yellow()
        );
        return Ok(Convergence::MustRecreate);
    }

    anyhow::bail!("{}", describe(name, &report))
}

/// Refuse to record a shape the live cluster does not have.
///
/// Only the fields a running cluster can be asked about are checked; the rest
/// are what the record exists for. But a node image that did not move is
/// exactly the case where convergence silently achieved nothing.
fn confirm_converged(
    name: &str,
    spec: &ClusterSpec,
    declared: &crate::domain::cluster_shape::ClusterShape,
) -> Result<()> {
    let Some(want) = declared.image.as_deref() else {
        return Ok(());
    };
    let Some(nodes) = io::kubectl::node_summary(&spec.kube_context) else {
        return Ok(());
    };
    let Some(running) = nodes.kubelet_version.as_deref() else {
        return Ok(());
    };

    // `rancher/k3s:v1.32.5-k3s1` against a kubelet of `v1.32.5+k3s1`.
    let want_version = want.rsplit(':').next().unwrap_or(want).replace('-', "+");
    if running.trim_start_matches('v') == want_version.trim_start_matches('v') {
        return Ok(());
    }

    anyhow::bail!(
        "cluster '{name}' was converged but still runs {running}, while the lab \
         declares {want}.\n\
         Nothing has been recorded, so the next run will try again rather than \
         reporting a match it does not have.\n\
         `cata diagnose` shows what the node reports."
    )
}

/// Bring a k3d cluster to its declared shape without losing it.
///
/// A k3d node keeps its datastore in a docker volume; the image only pins the
/// binary. So a version bump, an apiserver flag or a CNI toggle is a container
/// replacement against the same volume, and the cluster comes back as itself.
///
/// Nodes are replaced one at a time so a multi-server cluster keeps answering
/// throughout. A single-server cluster cannot: its API is down for the
/// restart, and the message says so rather than implying otherwise.
fn converge_k3d_in_place(
    name: &str,
    spec: &ClusterSpec,
    report: &crate::domain::cluster_shape::DriftReport,
    recorded: &crate::domain::cluster_shape::ClusterShape,
    docker_host: Option<&str>,
) -> Result<()> {
    use crate::domain::cluster_shape::Fix;

    let cluster = &spec.provisioner_config.k3d.cluster_name;

    for fix in report.fixes() {
        match fix {
            Fix::AddServers(n) => {
                let existing = io::k3d::node_names(cluster, docker_host).len().max(1);
                io::k3d::add_servers(cluster, n, existing, docker_host)?;
            }
            Fix::AddWorkers(n) => {
                let existing = io::k3d::node_names(cluster, docker_host).len().max(1);
                io::k3d::add_agents(cluster, n, existing, docker_host)?;
            }
            Fix::ReplaceLoadBalancer | Fix::ReplaceNode => {
                replace_k3d_nodes(name, spec, recorded, docker_host)?;
            }
            Fix::RebuildOnly => {
                println!(
                    "{} Cluster '{name}' keeps running as it is; the change is to \
                     which schemas its manifests are typed against",
                    style(">>>").cyan(),
                );
            }
            Fix::NewCluster => unreachable!("is_convergeable_in_place excluded this"),
        }
    }

    Ok(())
}

fn replace_k3d_nodes(
    name: &str,
    spec: &ClusterSpec,
    recorded: &crate::domain::cluster_shape::ClusterShape,
    docker_host: Option<&str>,
) -> Result<()> {
    let cluster = &spec.provisioner_config.k3d.cluster_name;
    let declared_version = &spec.kubernetes.version;

    if !io::k3d_node::upgrade_is_one_step(&recorded.version, declared_version) {
        anyhow::bail!(
            "cluster '{name}' runs Kubernetes {} and the lab declares {declared_version}.\n\
             Kubernetes supports one minor version of skew, so k3s cannot read a\n\
             datastore that far behind forward. Step through the minors one at a\n\
             time, or rebuild:\n  \
             cata lab up --recreate {name}",
            recorded.version,
        );
    }

    let image = io::k3d::node_image_for(spec);
    let nodes = io::k3d::node_names(cluster, docker_host);
    let servers: Vec<&String> = nodes.iter().filter(|n| n.contains("-server-")).collect();

    if servers.len() < 2 {
        println!(
            "{} Cluster '{name}' has one server, so its API is unavailable while \
             the node restarts. Its data is not touched.",
            style("note:").yellow(),
        );
    }

    for node in &nodes {
        // The loadbalancer holds no state and k3d rebuilds it from the
        // cluster; only the k3s nodes carry a datastore worth preserving.
        if node.contains("-serverlb") {
            continue;
        }
        println!(
            "{} Replacing node '{node}' on {image}, keeping its data",
            style(">>>").cyan(),
        );
        let node_spec = io::k3d_node::inspect(node)?;
        io::k3d_node::replace(&node_spec, &image, docker_host)?;
        // The API is down while the container restarts, and `kubectl wait`
        // treats ServiceUnavailable as a hard error rather than retrying, so
        // the cluster has to be answering before the node can be asked about.
        wait_until_answering(
            &spec.kube_context,
            &spec.provisioner_config.docker.wait_timeout,
        )?;
        io::k3d::wait_node_ready(&spec.kube_context, node)?;
    }

    Ok(())
}

/// A cluster with no record cannot be verified, but it can be checked against
/// what a live cluster does answer for.
///
/// When those agree, the record is written and the run continues. That is an
/// assertion about the fields nobody can read back, not a verification of
/// them, and it says so. When they disagree there is nothing to assert.
fn adopt_existing_cluster(
    name: &str,
    spec: &ClusterSpec,
    declared: &crate::domain::cluster_shape::ClusterShape,
) -> Result<crate::domain::cluster_shape::ClusterShape> {
    let observed = io::kubectl::node_summary(&spec.kube_context);

    let agrees = match &observed {
        Some(nodes) => describe_cluster_drift(
            spec.kubernetes.workers,
            nodes.workers,
            spec.provisioner_config.k3d.image.as_deref(),
            nodes.kubelet_version.as_deref(),
        )
        .is_empty(),
        None => false,
    };

    if !agrees {
        anyhow::bail!(
            "cluster '{name}' exists, but there is no record of the shape it was \
             built from and it does not match what the lab declares in the fields \
             a running cluster can be asked about.\n\
             That happens when it was built by an older catallaxy, on another \
             machine, or after the lab's state directory was cleared.\n\
             Recreate it so the two are known to agree:\n  \
             cata --flake .#<lab> lab up --recreate {name}"
        );
    }

    println!(
        "{} Cluster '{name}' predates the shape record. Its node count and k3s \
         version match the lab, so the record is being written from the current \
         declaration.",
        style(">>>").yellow()
    );
    println!(
        "      This asserts the fields a running cluster cannot be asked about \
         (apiserver args, CNI flags, volumes, subnets) rather than verifying \
         them. `lab up --recreate {name}` rebuilds it if you would rather know.",
    );

    crate::host::state::write_cluster_shape(&spec.lab_name, name, declared)?;
    Ok(declared.clone())
}

fn wait_until_answering(kube_context: &str, wait_timeout: &str) -> Result<()> {
    let timeout = crate::io::kubectl::parse_timeout(wait_timeout).with_context(|| {
        format!("provisioner.docker.waitTimeout is '{wait_timeout}', which is not a duration")
    })?;

    let answered = crate::io::poll::poll_while_time_remains(
        timeout,
        std::time::Duration::from_secs(2),
        || io::kubectl::api_reachable(kube_context).then_some(()),
    );
    if answered.is_some() {
        return Ok(());
    }

    anyhow::bail!(
        "cluster was created but '{kube_context}' did not answer within {wait_timeout}. \
         Raise provisioner.docker.waitTimeout if the machine is slow, or check \
         `docker logs` for the server node.",
    )
}

fn normalize_k3s_version(version: &str) -> String {
    version.replace('+', "-")
}

pub fn describe_cluster_drift(
    declared_workers: u32,
    actual_workers: u32,
    declared_image: Option<&str>,
    actual_version: Option<&str>,
) -> Vec<String> {
    let mut drift = Vec::new();

    if declared_workers != actual_workers {
        drift.push(format!(
            "cluster.kubernetes.workers is {declared_workers}, the cluster has {actual_workers}"
        ));
    }

    if let (Some(image), Some(version)) = (declared_image, actual_version) {
        let declared_version = image.rsplit(':').next().unwrap_or(image);
        if !declared_version.is_empty()
            && normalize_k3s_version(version) != normalize_k3s_version(declared_version)
        {
            drift.push(format!(
                "provisioner.k3d.image asks for {declared_version}, the nodes run {version}"
            ));
        }
    }

    drift
}

/// The record says the cluster was built from what the lab declares. This
/// asks the cluster itself, which catches what the record cannot: a node
/// added or removed behind catallaxy's back. Only the fields a live cluster
/// answers for honestly, and a warning rather than a refusal, because it is
/// corroboration rather than the check.
fn report_out_of_band_drift(name: &str, spec: &ClusterSpec) {
    let Some(nodes) = io::kubectl::node_summary(&spec.kube_context) else {
        return;
    };

    let drift = describe_cluster_drift(
        spec.kubernetes.workers,
        nodes.workers,
        spec.provisioner_config.k3d.image.as_deref(),
        nodes.kubelet_version.as_deref(),
    );

    if drift.is_empty() {
        return;
    }

    println!(
        "{} '{name}' was built from what the lab declares, but the running \
         cluster has since changed:",
        style("Warning:").yellow(),
    );
    for line in &drift {
        println!("    - {line}");
    }
    println!(
        "    Something outside catallaxy changed it. `lab up` does not reshape a \
         cluster that exists.\n    Recreate it to converge:  cata lab destroy && cata lab up"
    );
}

fn refuse_missing_mounts(cluster_name: &str, volumes: &[(String, String)]) -> Result<()> {
    let missing: Vec<&str> = volumes
        .iter()
        .filter(|(host_path, _)| !std::path::Path::new(host_path).exists())
        .map(|(host_path, _)| host_path.as_str())
        .collect();

    if missing.is_empty() {
        return Ok(());
    }

    anyhow::bail!(
        "cluster '{cluster_name}' declares volume mounts whose host paths do not exist:\n  {}\n\
         Docker would create empty directories there and the apiserver would fail to start \
         reading them as files. Nothing was created.\n\
         A client CA comes from `cata pki init {cluster_name}`. An audit policy file has no \
         generator yet, so cluster.security.auditLogging cannot work on k3d.",
        missing.join("\n  "),
    )
}

fn resolve_placeholders(path: &str, state_dir: &std::path::Path, cluster_name: &str) -> String {
    path.replace("{{STATE_DIR}}", &state_dir.display().to_string())
        .replace(
            "{{PKI_DIR}}",
            &crate::host::state::cluster_pki_dir(cluster_name)
                .display()
                .to_string(),
        )
        .replace("{{CLUSTER_NAME}}", cluster_name)
}

fn resolve_auto_deploy(
    ctx: &CataContext,
    name: &str,
    spec: &ClusterSpec,
    lab_package: Option<&str>,
) -> Vec<(String, String)> {
    let mut auto_deploy: Vec<(String, String)> = spec
        .provisioner_config
        .k3d
        .auto_deploy_manifests
        .iter()
        .map(|m| (m.name.clone(), m.path.clone()))
        .collect();

    if !auto_deploy.is_empty() {
        let lab_pkg = if let Some(pkg) = lab_package {
            Some(pkg.to_string())
        } else if let Ok(lab_name) = ctx.resolve_lab_name(None) {
            crate::io::nix::build_lab_package(ctx, &lab_name).ok()
        } else {
            None
        };
        if let Some(lab_pkg) = lab_pkg {
            auto_deploy = auto_deploy
                .into_iter()
                .map(|(n, p)| {
                    let pkg_path = format!("{lab_pkg}/autodeploy/{name}/{n}.yaml");
                    if std::path::Path::new(&pkg_path).exists() {
                        (n, pkg_path)
                    } else {
                        (n, p)
                    }
                })
                .collect();
        }
    }

    auto_deploy
}

pub fn ensure_lab_services(ctx: &CataContext, cluster_name: &str) -> Option<PathBuf> {
    let lab_names: Result<Vec<String>> = crate::io::nix::list_labs(ctx);
    let lab_names = match lab_names {
        Ok(names) => names,
        Err(_) => return None,
    };

    for lab_name in &lab_names {
        let lab = match crate::io::nix::get_lab_spec(ctx, lab_name) {
            Ok(lab) => lab,
            Err(_) => continue,
        };

        if !lab.cluster_names.iter().any(|n| n == cluster_name) {
            continue;
        }

        let provenance = crate::domain::provenance::Provenance::new(lab_name, ctx.flake_uri());
        for (svc_name, svc) in &lab.services {
            if let Err(e) =
                crate::host::services::start_service(lab_name, svc_name, svc, &provenance)
            {
                let description = svc.description.as_str();
                println!(
                    "{} Failed to start {}: {}",
                    style("Warning:").yellow(),
                    description,
                    e
                );
            }
        }

        if let Some(port) = lab.registry_port {
            let dns_ip = lab
                .dns_info
                .as_ref()
                .and(lab.dns_container())
                .and_then(io::docker::first_network_ip);
            match crate::host::registry::write_node_config(
                lab_name,
                port,
                &lab.registry_upstreams,
                lab.dns_info.as_ref().map(|d| d.zone.as_str()),
                dns_ip.as_deref(),
            ) {
                Ok(path) => return Some(path),
                Err(e) => println!(
                    "{} Could not write the registry config for '{lab_name}': {e:#}",
                    style("Warning:").yellow(),
                ),
            }
        }
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_matching_cluster_reports_no_drift() {
        assert!(
            describe_cluster_drift(2, 2, Some("rancher/k3s:v1.31.2-k3s1"), Some("v1.31.2+k3s1"))
                .is_empty()
        );
    }

    #[test]
    fn a_worker_count_change_is_drift() {
        let drift = describe_cluster_drift(3, 0, None, None);
        assert_eq!(drift.len(), 1, "{drift:?}");
        assert!(drift[0].contains("workers is 3"), "{drift:?}");
        assert!(drift[0].contains("has 0"), "{drift:?}");
    }

    #[test]
    fn a_k3s_version_change_is_drift() {
        let drift =
            describe_cluster_drift(0, 0, Some("rancher/k3s:v1.32.0-k3s1"), Some("v1.31.2+k3s1"));
        assert_eq!(drift.len(), 1, "{drift:?}");
        assert!(drift[0].contains("v1.32.0-k3s1"), "{drift:?}");
    }

    #[test]
    fn an_unknown_running_version_is_not_reported_as_drift() {
        assert!(describe_cluster_drift(0, 0, Some("rancher/k3s:v1.32.0-k3s1"), None).is_empty());
    }
}

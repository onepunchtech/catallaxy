use std::collections::BTreeMap;
use std::process::{Command, Stdio};

use anyhow::Result;

use super::*;
use crate::config::Context as CataContext;
use crate::domain::{ClusterSpec, LabSpec, StepParams};
use crate::io;

pub fn extract_static(lab: &LabSpec) -> LabTopology {
    let network = LabNetwork {
        name: lab.network.name.clone(),
        docker_subnet: lab.network.docker_subnet.clone(),
    };

    let services = extract_services(lab);
    let clusters = extract_clusters(lab);
    let mut edges = extract_edges_from_plan(lab);

    if services.contains_key("proxy") {
        extract_proxy_route_edges(&clusters, &mut edges);
    }

    LabTopology {
        name: lab.lab_name.clone(),
        zone: lab.dns_info.as_ref().map(|d| d.zone.clone()),
        cd_strategy: lab.cd.strategy.tag().to_string(),
        network,
        services,
        clusters,
        edges,
        deployment_plan: extract_plan_steps(lab),
    }
}

fn extract_services(lab: &LabSpec) -> BTreeMap<String, LabService> {
    let mut services = BTreeMap::new();
    for (name, svc) in &lab.services {
        services.insert(
            name.clone(),
            LabService {
                description: svc.description.clone(),
                container: svc.container.clone(),
                ports: svc.ports.clone(),
                running: None,
            },
        );
    }
    services
}

fn extract_clusters(lab: &LabSpec) -> BTreeMap<String, ClusterTopology> {
    let mut clusters = BTreeMap::new();

    for cluster_name in &lab.cluster_names {
        let Ok(cluster) = lab.cluster(cluster_name) else {
            continue;
        };

        let kube_context = lab
            .kube_context(cluster_name)
            .unwrap_or("<unresolved>")
            .to_string();
        let components = extract_components(cluster);

        clusters.insert(
            cluster_name.clone(),
            ClusterTopology {
                name: cluster_name.clone(),
                provider: cluster.provider.clone(),
                kube_context,
                control_planes: u64::from(cluster.kubernetes.control_planes),
                workers: u64::from(cluster.kubernetes.workers),
                pod_subnet: cluster.network.pod_subnet.clone(),
                service_subnet: cluster.network.service_subnet.clone(),
                components,
                live: None,
            },
        );
    }
    clusters
}

fn extract_components(cluster: &ClusterSpec) -> BTreeMap<String, ComponentSummary> {
    cluster
        .enabled_floes()
        .map(|(name, floe)| {
            (
                name.clone(),
                ComponentSummary {
                    enabled: true,
                    version: floe.version.clone(),
                    namespace: floe.namespace.clone().unwrap_or_else(|| name.clone()),
                    domain: floe.domain.clone().filter(|d| !d.is_empty()),
                    health: None,
                },
            )
        })
        .collect()
}

fn extract_edges_from_plan(lab: &LabSpec) -> Vec<TopologyEdge> {
    let mut edges = Vec::new();

    for step in &lab.deployment_plan {
        match &step.params {
            StepParams::CrossClusterSecretCopy {
                source_cluster,
                target_cluster,
                source_secret,
                ..
            } => edges.push(TopologyEdge {
                kind: EdgeKind::SecretCopy,
                source: source_cluster.clone(),
                target: target_cluster.clone(),
                label: Some(source_secret.clone()),
            }),
            StepParams::SyncKubeconfig {
                target, clusters, ..
            } => {
                for provisioned in clusters {
                    edges.push(TopologyEdge {
                        kind: EdgeKind::Provisions,
                        source: target.clone(),
                        target: provisioned.clone(),
                        label: None,
                    });
                }
            }
            StepParams::Pivot { cluster, .. } => edges.push(TopologyEdge {
                kind: EdgeKind::DeployDependency,
                source: format!("{cluster} (bootstrap)"),
                target: cluster.clone(),
                label: Some("pivot".to_string()),
            }),
            _ => {}
        }
    }
    edges
}

fn extract_proxy_route_edges(
    clusters: &BTreeMap<String, ClusterTopology>,
    edges: &mut Vec<TopologyEdge>,
) {
    for (cluster_name, cluster) in clusters {
        for (comp_name, comp) in &cluster.components {
            if let Some(domain) = &comp.domain {
                edges.push(TopologyEdge {
                    kind: EdgeKind::ProxyRoute,
                    source: "proxy".to_string(),
                    target: format!("{cluster_name}/{comp_name}"),
                    label: Some(domain.clone()),
                });
            }
        }
    }
}

fn extract_plan_steps(lab: &LabSpec) -> Vec<PlanStep> {
    lab.deployment_plan
        .iter()
        .map(|s| PlanStep {
            step_type: s.type_tag().to_string(),
            description: s.description.clone(),
            target: s.params.cluster_refs().first().map(|(_, c)| c.to_string()),
        })
        .collect()
}

pub fn enrich_live(_ctx: &CataContext, topo: &mut LabTopology) -> Result<()> {
    for svc in topo.services.values_mut() {
        if !svc.container.is_empty() {
            svc.running = Some(io::docker::container_running(&svc.container));
        }
    }

    for cluster in topo.clusters.values_mut() {
        let context = cluster.kube_context.clone();
        let reachable = io::kubectl::api_reachable(&context);

        if !reachable {
            cluster.live = Some(ClusterLiveState {
                reachable: false,
                nodes: vec![],
                kapp_apps: vec![],
            });
            continue;
        }

        let nodes = io::kubectl::get_node_status(&context)
            .unwrap_or_default()
            .iter()
            .map(|node| {
                let ready = node["status"]["conditions"]
                    .as_array()
                    .map(|conds| {
                        conds.iter().any(|c| {
                            c["type"].as_str() == Some("Ready")
                                && c["status"].as_str() == Some("True")
                        })
                    })
                    .unwrap_or(false);
                NodeSummary {
                    name: node["metadata"]["name"].as_str().unwrap_or("?").to_string(),
                    ready,
                    version: node["status"]["nodeInfo"]["kubeletVersion"]
                        .as_str()
                        .unwrap_or("?")
                        .to_string(),
                }
            })
            .collect();

        let kapp_apps = io::kubectl::get_kapp_app_statuses(&context)
            .unwrap_or_default()
            .into_iter()
            .map(|(name, status, age)| KappAppSummary {
                name: name.strip_prefix("cata-").unwrap_or(&name).to_string(),
                status,
                age,
            })
            .collect();

        cluster.live = Some(ClusterLiveState {
            reachable: true,
            nodes,
            kapp_apps,
        });

        for comp in cluster.components.values_mut() {
            comp.health = Some(check_namespace_health(&context, &comp.namespace));
        }
    }

    Ok(())
}

pub fn check_namespace_health(context: &str, namespace: &str) -> ComponentHealthState {
    let output = Command::new("kubectl")
        .args([
            "--context",
            context,
            "get",
            "pods",
            "-n",
            namespace,
            "-o",
            "json",
            "--request-timeout=3s",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output();

    let output = match output {
        Ok(o) if o.status.success() => o,
        _ => return ComponentHealthState::NoPods,
    };

    let json: serde_json::Value = match serde_json::from_slice(&output.stdout) {
        Ok(v) => v,
        Err(_) => return ComponentHealthState::NoPods,
    };

    let items = match json["items"].as_array() {
        Some(items) if !items.is_empty() => items,
        _ => return ComponentHealthState::NoPods,
    };

    let total = items.len();
    let ready = items
        .iter()
        .filter(|pod| {
            let phase = pod["status"]["phase"].as_str().unwrap_or("");
            match phase {
                "Succeeded" | "Completed" => true,
                "Running" => pod["status"]["containerStatuses"]
                    .as_array()
                    .map(|statuses| {
                        statuses
                            .iter()
                            .all(|cs| cs["ready"].as_bool() == Some(true))
                    })
                    .unwrap_or(false),
                _ => false,
            }
        })
        .count();

    if ready == total {
        ComponentHealthState::Healthy { pod_count: total }
    } else {
        ComponentHealthState::Degraded { ready, total }
    }
}

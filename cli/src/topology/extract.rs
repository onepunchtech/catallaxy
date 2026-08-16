use std::collections::BTreeMap;

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
            StepParams::SyncKubeconfig(p) => {
                for provisioned in &p.clusters {
                    edges.push(TopologyEdge {
                        kind: EdgeKind::Provisions,
                        source: p.target.clone(),
                        target: provisioned.clone(),
                        label: None,
                    });
                }
            }
            StepParams::Pivot(p) => edges.push(TopologyEdge {
                kind: EdgeKind::DeployDependency,
                source: format!("{} (bootstrap)", p.cluster),
                target: p.cluster.clone(),
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
    match crate::io::kubectl::pods_in_namespace(context, namespace, Some("3s")) {
        Some(pods) => health_of(&pods),
        None => ComponentHealthState::NoPods,
    }
}

fn pod_is_ready(pod: &serde_json::Value) -> bool {
    match pod["status"]["phase"].as_str().unwrap_or("") {
        "Succeeded" | "Completed" => true,
        "Running" => pod["status"]["containerStatuses"]
            .as_array()
            .is_some_and(|statuses| {
                statuses
                    .iter()
                    .all(|cs| cs["ready"].as_bool() == Some(true))
            }),
        _ => false,
    }
}

pub fn health_of(pods: &[serde_json::Value]) -> ComponentHealthState {
    if pods.is_empty() {
        return ComponentHealthState::NoPods;
    }

    let total = pods.len();
    let ready = pods.iter().filter(|p| pod_is_ready(p)).count();

    if ready == total {
        ComponentHealthState::Healthy { pod_count: total }
    } else {
        ComponentHealthState::Degraded { ready, total }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn pod(phase: &str, ready: &[bool]) -> serde_json::Value {
        json!({
            "status": {
                "phase": phase,
                "containerStatuses": ready.iter().map(|r| json!({ "ready": r })).collect::<Vec<_>>(),
            }
        })
    }

    #[test]
    fn no_pods_is_not_the_same_as_unhealthy() {
        assert_eq!(health_of(&[]), ComponentHealthState::NoPods);
    }

    #[test]
    fn every_container_ready_is_healthy() {
        let pods = vec![pod("Running", &[true, true]), pod("Running", &[true])];
        assert_eq!(
            health_of(&pods),
            ComponentHealthState::Healthy { pod_count: 2 }
        );
    }

    #[test]
    fn one_container_not_ready_degrades_its_pod() {
        let pods = vec![pod("Running", &[true, false]), pod("Running", &[true])];
        assert_eq!(
            health_of(&pods),
            ComponentHealthState::Degraded { ready: 1, total: 2 }
        );
    }

    #[test]
    fn a_finished_pod_counts_as_ready() {
        for phase in ["Succeeded", "Completed"] {
            assert_eq!(
                health_of(&[pod(phase, &[])]),
                ComponentHealthState::Healthy { pod_count: 1 },
                "{phase} is a job that finished, not a workload that is down"
            );
        }
    }

    #[test]
    fn a_pending_or_failed_pod_is_not_ready() {
        for phase in ["Pending", "Failed", "Unknown"] {
            assert_eq!(
                health_of(&[pod(phase, &[true])]),
                ComponentHealthState::Degraded { ready: 0, total: 1 },
                "{phase}"
            );
        }
    }

    #[test]
    fn a_running_pod_with_no_container_statuses_is_not_ready() {
        assert_eq!(
            health_of(&[json!({ "status": { "phase": "Running" } })]),
            ComponentHealthState::Degraded { ready: 0, total: 1 }
        );
    }
}

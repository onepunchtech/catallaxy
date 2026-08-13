use std::collections::BTreeMap;
use std::process::{Command, Stdio};

use anyhow::{Context as _, Result};

use super::*;
use crate::config::Context as CataContext;
use crate::domain::CdConfig;
use crate::domain::StepParams;
use crate::domain::lab::kube_context_in;
use crate::io;

pub fn extract_static(lab: &serde_json::Value) -> Result<LabTopology> {
    let name = lab["labName"].as_str().unwrap_or("unknown").to_string();
    let zone = lab
        .pointer("/dnsInfo/zone")
        .and_then(|v| v.as_str())
        .map(String::from);
    let cd: CdConfig = serde_json::from_value(lab["cd"].clone())
        .context("parsing lab.cd from the evaluated lab")?;
    let cd_strategy = cd.strategy.tag().to_string();

    let network = LabNetwork {
        name: lab
            .pointer("/network/name")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        docker_subnet: lab
            .pointer("/network/dockerSubnet")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
    };

    let services = extract_services(lab);

    let clusters = extract_clusters(lab);

    let mut edges = extract_edges_from_plan(lab);

    if services.contains_key("proxy") {
        extract_proxy_route_edges(lab, &clusters, &mut edges);
    }

    let deployment_plan = extract_plan_steps(lab);

    Ok(LabTopology {
        name,
        zone,
        cd_strategy,
        network,
        services,
        clusters,
        edges,
        deployment_plan,
    })
}

fn extract_services(lab: &serde_json::Value) -> BTreeMap<String, LabService> {
    let mut services = BTreeMap::new();
    if let Some(svcs) = lab["services"].as_object() {
        for (name, svc) in svcs {
            let ports = svc["ports"]
                .as_array()
                .map(|arr| {
                    arr.iter()
                        .filter_map(|v| v.as_str().map(String::from))
                        .collect()
                })
                .unwrap_or_default();

            services.insert(
                name.clone(),
                LabService {
                    description: svc["description"].as_str().unwrap_or("").to_string(),
                    container: svc["container"].as_str().unwrap_or("").to_string(),
                    ports,
                    running: None,
                },
            );
        }
    }
    services
}

fn extract_clusters(lab: &serde_json::Value) -> BTreeMap<String, ClusterTopology> {
    let mut clusters = BTreeMap::new();
    let cluster_names: Vec<String> = lab["clusterNames"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();

    for cluster_name in &cluster_names {
        let config = match crate::io::nix::get_cluster_config_from_lab(lab, cluster_name) {
            Ok(c) => c,
            Err(_) => continue,
        };

        let kube_context = kube_context_in(lab, cluster_name)
            .map(String::from)
            .unwrap_or_else(|_| "<unresolved>".to_string());
        let components = extract_components(&config);

        clusters.insert(
            cluster_name.clone(),
            ClusterTopology {
                name: cluster_name.clone(),
                provider: config["provider"].as_str().unwrap_or("?").to_string(),
                kube_context,
                control_planes: config
                    .pointer("/kubernetes/controlPlanes")
                    .and_then(|v| v.as_u64())
                    .unwrap_or(0),
                workers: config
                    .pointer("/kubernetes/workers")
                    .and_then(|v| v.as_u64())
                    .unwrap_or(0),
                pod_subnet: config
                    .pointer("/network/podSubnet")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string(),
                service_subnet: config
                    .pointer("/network/serviceSubnet")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string(),
                components,
                live: None,
            },
        );
    }
    clusters
}

fn extract_components(config: &serde_json::Value) -> BTreeMap<String, ComponentSummary> {
    let mut components = BTreeMap::new();
    if let Some(comps) = config["floes"].as_object() {
        for (name, comp) in comps {
            let enabled = comp["enable"].as_bool().unwrap_or(false);
            if !enabled {
                continue;
            }
            let domain = comp["domain"]
                .as_str()
                .filter(|d| !d.is_empty())
                .map(String::from);

            components.insert(
                name.clone(),
                ComponentSummary {
                    enabled,
                    version: comp["version"].as_str().map(String::from),
                    namespace: comp["namespace"].as_str().unwrap_or(name).to_string(),
                    domain,
                    health: None,
                },
            );
        }
    }
    components
}

fn extract_edges_from_plan(lab: &serde_json::Value) -> Vec<TopologyEdge> {
    let mut edges = Vec::new();

    for step in planned_steps(lab) {
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

fn planned_steps(lab: &serde_json::Value) -> Vec<crate::domain::PlannedStep> {
    lab["deploymentPlan"]
        .as_array()
        .map(|steps| {
            steps
                .iter()
                .filter_map(|s| serde_json::from_value(s.clone()).ok())
                .collect()
        })
        .unwrap_or_default()
}

fn extract_proxy_route_edges(
    _lab: &serde_json::Value,
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

fn extract_plan_steps(lab: &serde_json::Value) -> Vec<PlanStep> {
    planned_steps(lab)
        .into_iter()
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

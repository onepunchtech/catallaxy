use anyhow::Result;
use console::style;

use super::*;

pub fn render(topo: &LabTopology, format: TopologyFormat) -> Result<()> {
    match format {
        TopologyFormat::Json => {
            println!("{}", serde_json::to_string_pretty(topo)?);
        }
        TopologyFormat::Table => render_table(topo),
        TopologyFormat::Mermaid => println!("{}", render_mermaid(topo)),
        TopologyFormat::Dot => println!("{}", render_dot(topo)),
    }
    Ok(())
}

fn render_table(topo: &LabTopology) {
    println!(
        "{} Lab '{}' topology",
        style("catallaxy").cyan().bold(),
        style(&topo.name).green()
    );
    println!();

    let zone_str = topo.zone.as_deref().unwrap_or("?");
    println!(
        "  {} {} {} {} {} {} {}",
        style("strategy:").dim(),
        topo.cd_strategy,
        style("|").dim(),
        style("zone:").dim(),
        zone_str,
        style("|").dim(),
        style(format!("net: {}", topo.network.docker_subnet)).dim()
    );
    println!();

    render_services(topo);
    render_clusters(topo);
    render_edges(topo);
}

fn render_services(topo: &LabTopology) {
    if !topo.services.is_empty() {
        println!("{}", style("Services:").bold());
        for (name, svc) in &topo.services {
            let status = match svc.running {
                Some(true) => style("running").green(),
                Some(false) => style("stopped").red(),
                None => style("unknown").dim(),
            };
            let ports = if svc.ports.is_empty() {
                String::new()
            } else {
                format!(" {}", style(format!("[{}]", svc.ports.join(", "))).dim())
            };
            println!(
                "  {} ({}) [{}]{}",
                style(name).cyan(),
                svc.description,
                status,
                ports
            );
        }
        println!();
    }
}

fn render_clusters(topo: &LabTopology) {
    for cluster in topo.clusters.values() {
        let status = match &cluster.live {
            Some(live) if live.reachable => style("ready").green(),
            Some(_) => style("not ready").yellow(),
            None => style("static").dim(),
        };

        println!(
            "{} {} [{}] (context: {})",
            style("Cluster").bold(),
            style(&cluster.name).green().bold(),
            status,
            style(&cluster.kube_context).dim(),
        );
        println!(
            "  {} {}  {} {}cp/{}w  {} pods={} svc={}",
            style("provider:").dim(),
            cluster.provider,
            style("|").dim(),
            cluster.control_planes,
            cluster.workers,
            style("|").dim(),
            cluster.pod_subnet,
            cluster.service_subnet,
        );

        if let Some(live) = &cluster.live
            && !live.nodes.is_empty()
        {
            println!("  {}", style("Nodes:").dim());
            for node in &live.nodes {
                let node_status = if node.ready {
                    style("Ready").green()
                } else {
                    style("NotReady").red()
                };
                println!(
                    "    {} [{}] {}",
                    style(&node.name).cyan(),
                    node_status,
                    node.version
                );
            }
        }

        if !cluster.components.is_empty() {
            println!("  {}", style("Components:").dim());
            for (comp_name, comp) in &cluster.components {
                let version = comp
                    .version
                    .as_deref()
                    .filter(|v| !v.is_empty())
                    .map(|v| {
                        if v.starts_with('v') {
                            format!(" {v}")
                        } else {
                            format!(" v{v}")
                        }
                    })
                    .unwrap_or_default();

                let health_str = match &comp.health {
                    Some(ComponentHealthState::Healthy { pod_count }) => {
                        format!(" ({})", style(format!("{pod_count} pods")).green())
                    }
                    Some(ComponentHealthState::Degraded { ready, total }) => {
                        format!(" ({})", style(format!("{ready}/{total} ready")).yellow())
                    }
                    Some(ComponentHealthState::NoPods) => {
                        format!(" ({})", style("no pods").dim())
                    }
                    None => String::new(),
                };

                let domain_str = comp
                    .domain
                    .as_ref()
                    .map(|d| format!(" {}", style(d).dim()))
                    .unwrap_or_default();

                println!(
                    "    {} {}{} {}{}{}",
                    style("-").dim(),
                    style(comp_name).cyan(),
                    style(version).dim(),
                    style(format!("[{}]", comp.namespace)).dim(),
                    health_str,
                    domain_str,
                );
            }
        }
        println!();
    }
}

fn render_edges(topo: &LabTopology) {
    if !topo.edges.is_empty() {
        println!("{}", style("Relationships:").bold());
        for edge in &topo.edges {
            let kind_str = match edge.kind {
                EdgeKind::ProxyRoute => "route",
                EdgeKind::SecretCopy => "secret-copy",
                EdgeKind::DeployDependency => "depends-on",
                EdgeKind::Provisions => "provisions",
            };
            let label = edge
                .label
                .as_ref()
                .map(|l| format!(" ({l})"))
                .unwrap_or_default();
            println!(
                "  {} --[{}]--> {}{}",
                style(&edge.source).cyan(),
                style(kind_str).dim(),
                style(&edge.target).cyan(),
                style(&label).dim()
            );
        }
        println!();
    }
}

fn render_mermaid(topo: &LabTopology) -> String {
    let mut out = String::new();
    out.push_str("graph TD\n");

    let lab_id = sanitize_mermaid_id(&topo.name);
    out.push_str(&format!("    subgraph {lab_id}[\"{}\"]\n", topo.name));

    for (name, svc) in &topo.services {
        let id = sanitize_mermaid_id(name);
        out.push_str(&format!("        {id}[\"{name} ({})\"]\n", svc.description));
    }

    for (cluster_name, cluster) in &topo.clusters {
        let cluster_id = sanitize_mermaid_id(cluster_name);
        out.push_str(&format!(
            "        subgraph {cluster_id}[\"{cluster_name} ({})\"]\n",
            cluster.provider
        ));
        for (comp_name, comp) in &cluster.components {
            let comp_id = format!(
                "{}_{}",
                sanitize_mermaid_id(cluster_name),
                sanitize_mermaid_id(comp_name)
            );
            let version = comp
                .version
                .as_deref()
                .map(|v| format!(" v{v}"))
                .unwrap_or_default();
            out.push_str(&format!(
                "            {comp_id}[\"{comp_name}{version}\"]\n"
            ));
        }
        out.push_str("        end\n");
    }

    out.push_str("    end\n");

    for edge in &topo.edges {
        let source_id = resolve_mermaid_id(topo, &edge.source);
        let target_id = resolve_mermaid_id(topo, &edge.target);
        let label = edge.label.as_deref().unwrap_or("");
        let kind_str = match edge.kind {
            EdgeKind::ProxyRoute => "route",
            EdgeKind::SecretCopy => "secret",
            EdgeKind::DeployDependency => "depends",
            EdgeKind::Provisions => "provisions",
        };
        let edge_label = if label.is_empty() {
            kind_str.to_string()
        } else {
            format!("{kind_str}: {label}")
        };
        out.push_str(&format!(
            "    {source_id} -->|\"{edge_label}\"| {target_id}\n"
        ));
    }

    out
}

fn render_dot(topo: &LabTopology) -> String {
    let mut out = String::new();
    out.push_str("digraph lab {\n");
    out.push_str("    rankdir=LR;\n");
    out.push_str("    node [shape=box, style=filled, fillcolor=lightblue];\n");
    out.push_str(&format!("    label=\"{}\";\n", topo.name));
    out.push_str("    labelloc=t;\n\n");

    for (name, svc) in &topo.services {
        let id = sanitize_dot_id(name);
        out.push_str(&format!(
            "    {id} [label=\"{name}\\n{}\", fillcolor=lightyellow];\n",
            svc.description
        ));
    }
    out.push('\n');

    for (cluster_name, cluster) in &topo.clusters {
        let subgraph_id = sanitize_dot_id(cluster_name);
        out.push_str(&format!("    subgraph cluster_{subgraph_id} {{\n"));
        out.push_str(&format!(
            "        label=\"{cluster_name} ({})\\npods={} svc={}\";\n",
            cluster.provider, cluster.pod_subnet, cluster.service_subnet
        ));
        out.push_str("        style=filled;\n");
        out.push_str("        color=lightgrey;\n");
        out.push_str("        fillcolor=white;\n");

        for (comp_name, comp) in &cluster.components {
            let comp_id = format!(
                "{}_{}",
                sanitize_dot_id(cluster_name),
                sanitize_dot_id(comp_name)
            );
            let version = comp
                .version
                .as_deref()
                .map(|v| format!(" v{v}"))
                .unwrap_or_default();
            out.push_str(&format!(
                "        {comp_id} [label=\"{comp_name}{version}\\n[{}]\"];\n",
                comp.namespace
            ));
        }
        out.push_str("    }\n\n");
    }

    for edge in &topo.edges {
        let source_id = resolve_dot_id(topo, &edge.source);
        let target_id = resolve_dot_id(topo, &edge.target);
        let label = edge.label.as_deref().unwrap_or("");
        let kind_str = match edge.kind {
            EdgeKind::ProxyRoute => "route",
            EdgeKind::SecretCopy => "secret",
            EdgeKind::DeployDependency => "depends",
            EdgeKind::Provisions => "provisions",
        };
        let edge_label = if label.is_empty() {
            kind_str.to_string()
        } else {
            format!("{kind_str}: {label}")
        };
        let edge_style = match edge.kind {
            EdgeKind::ProxyRoute => ", color=blue",
            EdgeKind::SecretCopy => ", color=red, style=dashed",
            EdgeKind::Provisions => ", color=green",
            EdgeKind::DeployDependency => ", style=dotted",
        };
        out.push_str(&format!(
            "    {source_id} -> {target_id} [label=\"{edge_label}\"{edge_style}];\n"
        ));
    }

    out.push_str("}\n");
    out
}

fn sanitize_mermaid_id(s: &str) -> String {
    s.replace(['-', '.', '/', ' '], "_")
}

fn resolve_mermaid_id(topo: &LabTopology, endpoint: &str) -> String {
    if let Some((cluster, comp)) = endpoint.split_once('/') {
        return format!(
            "{}_{}",
            sanitize_mermaid_id(cluster),
            sanitize_mermaid_id(comp)
        );
    }
    if topo.services.contains_key(endpoint) || topo.clusters.contains_key(endpoint) {
        return sanitize_mermaid_id(endpoint);
    }
    sanitize_mermaid_id(endpoint)
}

fn sanitize_dot_id(s: &str) -> String {
    s.replace(['-', '.', '/', ' ', '(', ')'], "_")
}

fn resolve_dot_id(topo: &LabTopology, endpoint: &str) -> String {
    if let Some((cluster, comp)) = endpoint.split_once('/') {
        return format!("{}_{}", sanitize_dot_id(cluster), sanitize_dot_id(comp));
    }
    if topo.services.contains_key(endpoint) || topo.clusters.contains_key(endpoint) {
        return sanitize_dot_id(endpoint);
    }
    sanitize_dot_id(endpoint)
}

use std::fmt::Write;

use anyhow::Result;
use console::style;

use super::*;

pub fn render(topo: &LabTopology, format: TopologyFormat) -> Result<String> {
    Ok(match format {
        // The table writes its own line breaks as it goes; the other three are
        // documents that the caller used to hand to println!, which is one
        // trailing newline more than the document carries.
        TopologyFormat::Table => render_table(topo),
        TopologyFormat::Json => serde_json::to_string_pretty(topo)? + "\n",
        TopologyFormat::Mermaid => render_mermaid(topo) + "\n",
        TopologyFormat::Dot => render_dot(topo) + "\n",
    })
}

fn render_table(topo: &LabTopology) -> String {
    let mut out = String::new();

    let _ = writeln!(
        out,
        "{} Lab '{}' topology",
        style("catallaxy").cyan().bold(),
        style(&topo.name).green()
    );
    let _ = writeln!(out);

    let zone_str = topo.zone.as_deref().unwrap_or("?");
    let _ = writeln!(
        out,
        "  {} {} {} {} {} {} {}",
        style("strategy:").dim(),
        topo.cd_strategy,
        style("|").dim(),
        style("zone:").dim(),
        zone_str,
        style("|").dim(),
        style(format!("net: {}", topo.network.docker_subnet)).dim()
    );
    let _ = writeln!(out);

    out.push_str(&render_services(topo));
    out.push_str(&render_clusters(topo));
    out.push_str(&render_edges(topo));
    out
}

fn render_services(topo: &LabTopology) -> String {
    let mut out = String::new();
    if topo.services.is_empty() {
        return out;
    }

    let _ = writeln!(out, "{}", style("Services:").bold());
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
        let _ = writeln!(
            out,
            "  {} ({}) [{}]{}",
            style(name).cyan(),
            svc.description,
            status,
            ports
        );
    }
    let _ = writeln!(out);
    out
}

fn render_node_lines(live: &ClusterLiveState) -> String {
    let mut out = String::new();
    if live.nodes.is_empty() {
        return out;
    }

    let _ = writeln!(out, "  {}", style("Nodes:").dim());
    for node in &live.nodes {
        let node_status = if node.ready {
            style("Ready").green()
        } else {
            style("NotReady").red()
        };
        let _ = writeln!(
            out,
            "    {} [{}] {}",
            style(&node.name).cyan(),
            node_status,
            node.version
        );
    }
    out
}

pub fn version_suffix(version: Option<&str>) -> String {
    version
        .filter(|v| !v.is_empty())
        .map(|v| {
            if v.starts_with('v') {
                format!(" {v}")
            } else {
                format!(" v{v}")
            }
        })
        .unwrap_or_default()
}

fn health_suffix(health: Option<&ComponentHealthState>) -> String {
    match health {
        Some(ComponentHealthState::Healthy { pod_count }) => {
            format!(" ({})", style(format!("{pod_count} pods")).green())
        }
        Some(ComponentHealthState::Degraded { ready, total }) => {
            format!(" ({})", style(format!("{ready}/{total} ready")).yellow())
        }
        Some(ComponentHealthState::NoPods) => format!(" ({})", style("no pods").dim()),
        None => String::new(),
    }
}

fn render_component_lines(cluster: &ClusterTopology) -> String {
    let mut out = String::new();
    if cluster.components.is_empty() {
        return out;
    }

    let _ = writeln!(out, "  {}", style("Components:").dim());
    for (comp_name, comp) in &cluster.components {
        let domain_str = comp
            .domain
            .as_ref()
            .map(|d| format!(" {}", style(d).dim()))
            .unwrap_or_default();

        let _ = writeln!(
            out,
            "    {} {}{} {}{}{}",
            style("-").dim(),
            style(comp_name).cyan(),
            style(version_suffix(comp.version.as_deref())).dim(),
            style(format!("[{}]", comp.namespace)).dim(),
            health_suffix(comp.health.as_ref()),
            domain_str,
        );
    }
    out
}

fn render_clusters(topo: &LabTopology) -> String {
    let mut out = String::new();

    for cluster in topo.clusters.values() {
        let status = match &cluster.live {
            Some(live) if live.reachable => style("ready").green(),
            Some(_) => style("not ready").yellow(),
            None => style("static").dim(),
        };

        let _ = writeln!(
            out,
            "{} {} [{}] (context: {})",
            style("Cluster").bold(),
            style(&cluster.name).green().bold(),
            status,
            style(&cluster.kube_context).dim(),
        );
        let _ = writeln!(
            out,
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

        if let Some(live) = &cluster.live {
            out.push_str(&render_node_lines(live));
        }
        out.push_str(&render_component_lines(cluster));
        let _ = writeln!(out);
    }
    out
}

pub fn edge_kind_label(kind: &EdgeKind) -> &'static str {
    match kind {
        EdgeKind::ProxyRoute => "route",
        EdgeKind::DeployDependency => "depends-on",
        EdgeKind::Provisions => "provisions",
    }
}

fn render_edges(topo: &LabTopology) -> String {
    let mut out = String::new();
    if topo.edges.is_empty() {
        return out;
    }

    let _ = writeln!(out, "{}", style("Relationships:").bold());
    for edge in &topo.edges {
        let label = edge
            .label
            .as_ref()
            .map(|l| format!(" ({l})"))
            .unwrap_or_default();
        let _ = writeln!(
            out,
            "  {} --[{}]--> {}{}",
            style(&edge.source).cyan(),
            style(edge_kind_label(&edge.kind)).dim(),
            style(&edge.target).cyan(),
            style(&label).dim()
        );
    }
    let _ = writeln!(out);
    out
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_version_gains_a_v_only_when_it_lacks_one() {
        assert_eq!(version_suffix(Some("1.2.3")), " v1.2.3");
        assert_eq!(version_suffix(Some("v1.2.3")), " v1.2.3");
    }

    #[test]
    fn an_absent_or_empty_version_renders_nothing() {
        assert_eq!(version_suffix(None), "");
        assert_eq!(version_suffix(Some("")), "");
    }

    #[test]
    fn every_edge_kind_has_a_label() {
        for kind in [
            EdgeKind::ProxyRoute,
            EdgeKind::DeployDependency,
            EdgeKind::Provisions,
        ] {
            assert!(!edge_kind_label(&kind).is_empty());
        }
    }
}

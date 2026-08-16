//! Whether the network policies match what the software is configured to do.
//!
//! Policies are the one thing a lab renders whose correctness normally shows
//! up only on a running cluster with an enforcing CNI: a wrong port number
//! builds fine and fails as a timeout somewhere. Declaring a flow at both
//! ends and checking the two agree does not help, because two wrong numbers
//! agree perfectly well.
//!
//! The rendered manifests already say what talks to what. Every Service with
//! its real ports is there, and so is every URL a chart was configured with.
//! That is ground truth, and comparing the policies against it needs no
//! cluster.
//!
//! Three findings:
//!
//! - a `serves` port no Service exposes, which is a number someone got wrong
//! - a service reference no policy permits, which is traffic that will hang
//! - a permitted flow nothing references, which is over-permission
//!
//! The last is a warning rather than an error: a legitimate flow need not
//! appear as a URL anywhere, so demanding one would mean suppressions.
//!
//! One blind spot worth knowing about: a rule whose ports are all named rather
//! than numbered permits no flow this can see, because the name belongs to the
//! container and nothing here resolves it to a number. That can only produce a
//! spurious "no policy permits it", never a missed one.

use std::collections::{BTreeMap, BTreeSet, HashSet};

use serde_yaml::Value;

use crate::domain::diagnostic::{Diagnostic, Severity};
use crate::lint::manifest::K8sResource;

use super::{CheckContext, CheckRule};

pub struct NetworkPolicies;

impl CheckRule for NetworkPolicies {
    fn name(&self) -> &'static str {
        "network-policy"
    }

    fn check(&self, ctx: &CheckContext<'_>) -> Vec<Diagnostic> {
        check(ctx)
    }
}

/// A namespace reached on a port.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct Flow {
    from: String,
    to: String,
    port: u32,
}

/// `(namespace, service name) -> ports`.
type Services = BTreeMap<(String, String), BTreeSet<u32>>;

fn service_inventory(resources: &[K8sResource]) -> Services {
    let mut out: Services = BTreeMap::new();
    for r in resources.iter().filter(|r| r.kind == "Service") {
        let Some(ns) = r.namespace.as_deref() else {
            continue;
        };
        let entry = out.entry((ns.to_string(), r.name.clone())).or_default();
        let ports = r
            .raw
            .get("spec")
            .and_then(|s| s.get("ports"))
            .and_then(Value::as_sequence);
        for p in ports.into_iter().flatten() {
            if let Some(n) = p.get("port").and_then(port_number) {
                entry.insert(n);
            }
        }
    }
    out
}

fn port_number(v: &Value) -> Option<u32> {
    match v {
        Value::Number(n) => n.as_u64().map(|n| n as u32),
        Value::String(s) => s.parse().ok(),
        _ => None,
    }
}

fn json_port(v: &serde_json::Value) -> Option<u32> {
    match v {
        serde_json::Value::Number(n) => n.as_u64().map(|n| n as u32),
        serde_json::Value::String(s) => s.parse().ok(),
        _ => None,
    }
}

/// Service references in a rendered document, as `(service, namespace, port)`.
///
/// Two spellings are recognised, `<svc>.<ns>.svc.cluster.local[:port]` and the
/// short `<svc>.<ns>:<port>`. The short form also matches ordinary domain
/// names, so a candidate is kept only when the namespace is one the lab
/// manages and the service exists in it. That resolves `yandex.net:443` away
/// and keeps `prometheus-kube-prometheus-prometheus.prometheus:9090`, with no
/// heuristics beyond the inventory itself.
fn references_in(text: &str) -> Vec<(String, String, Option<u32>)> {
    let mut out = Vec::new();
    let bytes: Vec<char> = text.chars().collect();

    let is_name = |c: char| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-';

    let mut i = 0;
    while i < bytes.len() {
        if !is_name(bytes[i]) || (i > 0 && (is_name(bytes[i - 1]) || bytes[i - 1] == '.')) {
            i += 1;
            continue;
        }

        let start = i;
        let mut labels: Vec<String> = Vec::new();
        let mut j = i;
        loop {
            let ls = j;
            while j < bytes.len() && is_name(bytes[j]) {
                j += 1;
            }
            if j == ls {
                break;
            }
            labels.push(bytes[ls..j].iter().collect());
            if j < bytes.len() && bytes[j] == '.' {
                j += 1;
            } else {
                break;
            }
        }

        let mut port = None;
        if j < bytes.len() && bytes[j] == ':' {
            let ps = j + 1;
            let mut pe = ps;
            while pe < bytes.len() && bytes[pe].is_ascii_digit() {
                pe += 1;
            }
            if pe > ps {
                port = bytes[ps..pe].iter().collect::<String>().parse().ok();
                j = pe;
            }
        }

        // `svc` by where it is rather than by which label it is: the service
        // and its namespace are the two labels before it, and what follows is
        // the cluster domain or nothing. Matching it at a fixed position read
        // only `<svc>.<ns>.svc.cluster.local` and dropped both `<svc>.<ns>.svc`
        // and the `<pod>.<svc>.<ns>.svc.cluster.local` a StatefulSet uses.
        let svc_at = labels
            .iter()
            .position(|l| l.as_str() == "svc")
            .filter(|&k| {
                let rest = &labels[k + 1..];
                k >= 2 && (rest.is_empty() || rest == ["cluster", "local"])
            });

        if let Some(k) = svc_at {
            out.push((labels[k - 2].clone(), labels[k - 1].clone(), port));
        } else if labels.len() == 2 {
            out.push((labels[0].clone(), labels[1].clone(), port));
        }

        i = if j > start { j } else { start + 1 };
    }

    out
}

/// Flows the rendered policies allow, as namespace pairs on a port.
///
/// Both dialects, since a lab renders whichever its CNI understands. Only
/// rules naming a namespace count: an ipBlock is off-cluster by construction
/// and never satisfies an in-cluster reference.
fn permitted(resources: &[K8sResource]) -> BTreeSet<Flow> {
    let mut out = BTreeSet::new();

    for r in resources {
        let Some(ns) = r.namespace.as_deref() else {
            continue;
        };
        let Some(spec) = r.raw.get("spec") else {
            continue;
        };

        match r.kind.as_str() {
            "NetworkPolicy" => {
                collect_plain(spec, "egress", "to", ns, true, &mut out);
                collect_plain(spec, "ingress", "from", ns, false, &mut out);
            }
            "CiliumNetworkPolicy" => {
                collect_cilium(spec, "egress", "toEndpoints", "toPorts", ns, true, &mut out);
                collect_cilium(
                    spec,
                    "ingress",
                    "fromEndpoints",
                    "toPorts",
                    ns,
                    false,
                    &mut out,
                );
            }
            _ => {}
        }
    }

    out
}

fn rule_ports(rule: &Value, key: &str) -> Vec<u32> {
    rule.get(key)
        .and_then(Value::as_sequence)
        .map(|ps| {
            ps.iter()
                .filter_map(|p| p.get("port").and_then(port_number))
                .collect()
        })
        .unwrap_or_default()
}

fn add_flows(own: &str, other: &str, ports: &[u32], egress: bool, out: &mut BTreeSet<Flow>) {
    for &port in ports {
        let (from, to) = if egress {
            (own.to_string(), other.to_string())
        } else {
            (other.to_string(), own.to_string())
        };
        out.insert(Flow { from, to, port });
    }
}

fn collect_plain(
    spec: &Value,
    section: &str,
    peer_key: &str,
    ns: &str,
    egress: bool,
    out: &mut BTreeSet<Flow>,
) {
    let Some(rules) = spec.get(section).and_then(Value::as_sequence) else {
        return;
    };
    for rule in rules {
        let ports = rule_ports(rule, "ports");
        if ports.is_empty() {
            continue;
        }
        let peers = rule.get(peer_key).and_then(Value::as_sequence);
        for peer in peers.into_iter().flatten() {
            if let Some(other) = peer
                .get("namespaceSelector")
                .and_then(|s| s.get("matchLabels"))
                .and_then(|l| l.get("kubernetes.io/metadata.name"))
                .and_then(Value::as_str)
            {
                add_flows(ns, other, &ports, egress, out);
            }
        }
    }
}

fn collect_cilium(
    spec: &Value,
    section: &str,
    peer_key: &str,
    ports_key: &str,
    ns: &str,
    egress: bool,
    out: &mut BTreeSet<Flow>,
) {
    let Some(rules) = spec.get(section).and_then(Value::as_sequence) else {
        return;
    };
    for rule in rules {
        let ports: Vec<u32> = rule
            .get(ports_key)
            .and_then(Value::as_sequence)
            .map(|groups| {
                groups
                    .iter()
                    .filter_map(|g| g.get("ports").and_then(Value::as_sequence))
                    .flatten()
                    .filter_map(|p| p.get("port").and_then(port_number))
                    .collect()
            })
            .unwrap_or_default();
        if ports.is_empty() {
            continue;
        }
        let peers = rule.get(peer_key).and_then(Value::as_sequence);
        for peer in peers.into_iter().flatten() {
            if let Some(other) = peer
                .get("matchLabels")
                .and_then(|l| l.get("k8s:io.kubernetes.pod.namespace"))
                .and_then(Value::as_str)
            {
                add_flows(ns, other, &ports, egress, out);
            }
        }
    }
}

fn check(ctx: &CheckContext<'_>) -> Vec<Diagnostic> {
    let mut out = Vec::new();

    let meta = match ctx.cluster_meta {
        Some(m) => &m.network_policies,
        None => return out,
    };

    let services = service_inventory(ctx.resources);

    out.extend(served_ports_exist(ctx, &services));

    // Without policies there is nothing to be missing from.
    if !meta.enabled {
        return out;
    }

    out.extend(flows_match_references(ctx, &services));
    out
}

/// A declared port that no Service exposes is wrong whether or not this lab
/// enforces policies, so this half runs either way.
fn served_ports_exist(ctx: &CheckContext<'_>, services: &Services) -> Vec<Diagnostic> {
    let mut out = Vec::new();
    let Some(meta) = ctx.cluster_meta.map(|m| &m.network_policies) else {
        return out;
    };

    for (floe, decl) in &meta.floes {
        let exposed: BTreeSet<u32> = decl
            .namespaces
            .iter()
            .flat_map(|ns| {
                services
                    .iter()
                    .filter(move |((sns, _), _)| sns == ns)
                    .flat_map(|(_, ports)| ports.iter().copied())
            })
            .collect();

        if exposed.is_empty() {
            continue;
        }

        for (label, served) in &decl.serves {
            // A named port is the container's name for it, which a Service
            // spec carries as a target rather than a port, so there is
            // nothing here to compare it against.
            let Some(port) = json_port(&served.port) else {
                continue;
            };
            if !exposed.contains(&port) {
                out.push(Diagnostic {
                    severity: Severity::Error,
                    check: "network-policy",
                    cluster: ctx.cluster.to_string(),
                    file: Default::default(),
                    resource: format!("{floe}/{label}"),
                    message: format!(
                        "serves port {port}, but no Service in {} exposes it (it exposes {})",
                        decl.namespaces.join(", "),
                        exposed
                            .iter()
                            .map(u32::to_string)
                            .collect::<Vec<_>>()
                            .join(", ")
                    ),
                });
            }
        }
    }

    out
}

/// What the manifests are configured to do, against what the policies allow.
fn flows_match_references(ctx: &CheckContext<'_>, services: &Services) -> Vec<Diagnostic> {
    let mut out = Vec::new();
    let lab_ns: HashSet<&str> = ctx.lab_namespaces.iter().map(String::as_str).collect();
    let allowed = permitted(ctx.resources);

    // Every in-cluster reference the manifests carry, attributed to the
    // namespace of the resource holding it.
    let mut required: BTreeMap<Flow, String> = BTreeMap::new();

    // A reference in a cluster-scoped resource is real but unattributable:
    // a ClusterSecretStore naming openbao is read by a controller somewhere,
    // and nothing in the document says where. Enough to stop calling the
    // matching rule unused, not enough to demand one exists.
    let mut anonymous: BTreeSet<(String, u32)> = BTreeSet::new();

    route_references(ctx, &mut required);
    text_references(ctx, services, &lab_ns, &mut required, &mut anonymous);

    for (flow, by) in &required {
        if !allowed.contains(flow) {
            out.push(Diagnostic {
                severity: Severity::Error,
                check: "network-policy",
                cluster: ctx.cluster.to_string(),
                file: Default::default(),
                resource: by.clone(),
                message: format!(
                    "{} is configured to reach {}:{}, but no policy permits it",
                    flow.from, flow.to, flow.port
                ),
            });
        }
    }

    for flow in &allowed {
        if !required.contains_key(flow) && !anonymous.contains(&(flow.to.clone(), flow.port)) {
            out.push(Diagnostic {
                severity: Severity::Warning,
                check: "network-policy",
                cluster: ctx.cluster.to_string(),
                file: Default::default(),
                resource: format!("{}/{}", flow.from, flow.to),
                message: format!(
                    "{} may reach {}:{}, but nothing references it",
                    flow.from, flow.to, flow.port
                ),
            });
        }
    }

    out
}

/// A route is a reference too. The gateway reaches its backends because the
/// route says so, not because any URL spells it out, so without this every
/// exposed floe reports as permitted-but-unreferenced.
fn route_references(ctx: &CheckContext<'_>, required: &mut BTreeMap<Flow, String>) {
    for r in ctx.resources.iter().filter(|r| r.kind == "HTTPRoute") {
        let Some(route_ns) = r.namespace.as_deref() else {
            continue;
        };
        let parents = r
            .raw
            .get("spec")
            .and_then(|s| s.get("parentRefs"))
            .and_then(Value::as_sequence);
        let gw_ns: Vec<String> = parents
            .into_iter()
            .flatten()
            .filter_map(|p| p.get("namespace").and_then(Value::as_str))
            .map(str::to_string)
            .collect();

        let rules = r
            .raw
            .get("spec")
            .and_then(|s| s.get("rules"))
            .and_then(Value::as_sequence);
        for backend in rules
            .into_iter()
            .flatten()
            .filter_map(|rule| rule.get("backendRefs").and_then(Value::as_sequence))
            .flatten()
        {
            let Some(port) = backend.get("port").and_then(port_number) else {
                continue;
            };
            let to = backend
                .get("namespace")
                .and_then(Value::as_str)
                .unwrap_or(route_ns);
            for from in &gw_ns {
                if from != to {
                    required
                        .entry(Flow {
                            from: from.clone(),
                            to: to.to_string(),
                            port,
                        })
                        .or_insert_with(|| r.display_id());
                }
            }
        }
    }
}

/// Every in-cluster reference the manifests carry, attributed to the
/// namespace of the resource holding it.
fn text_references(
    ctx: &CheckContext<'_>,
    services: &Services,
    lab_ns: &HashSet<&str>,
    required: &mut BTreeMap<Flow, String>,
    anonymous: &mut BTreeSet<(String, u32)>,
) {
    for r in ctx.resources {
        let src = r.namespace.as_deref();
        let Ok(text) = serde_yaml::to_string(&r.raw) else {
            continue;
        };
        for (svc, ns, port) in references_in(&text) {
            if !lab_ns.contains(ns.as_str()) || src == Some(ns.as_str()) {
                continue;
            }
            let Some(ports) = services.get(&(ns.clone(), svc.clone())) else {
                continue;
            };
            let wanted: Vec<u32> = match port {
                Some(p) if ports.contains(&p) => vec![p],
                Some(_) => continue,
                None => ports.iter().copied().collect(),
            };
            for p in wanted {
                match src {
                    Some(src) => {
                        required
                            .entry(Flow {
                                from: src.to_string(),
                                to: ns.clone(),
                                port: p,
                            })
                            .or_insert_with(|| r.display_id());
                    }
                    None => {
                        anonymous.insert((ns.clone(), p));
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn refs(s: &str) -> Vec<(String, String, Option<u32>)> {
        references_in(s)
    }

    #[test]
    fn reads_a_fully_qualified_reference() {
        assert!(
            refs("url: http://loki.loki.svc.cluster.local:3100/ready").contains(&(
                "loki".into(),
                "loki".into(),
                Some(3100)
            ))
        );
    }

    #[test]
    fn reads_a_short_reference() {
        assert!(
            refs("addr: prometheus-kube-prometheus-prometheus.prometheus:9090").contains(&(
                "prometheus-kube-prometheus-prometheus".into(),
                "prometheus".into(),
                Some(9090)
            ))
        );
    }

    // A StatefulSet addresses one pod through its headless Service, which puts
    // the pod's name in front of the form above.
    #[test]
    fn reads_a_pod_reference_through_a_headless_service() {
        assert!(
            refs("peer: loki-0.loki-headless.loki.svc.cluster.local:9095").contains(&(
                "loki-headless".into(),
                "loki".into(),
                Some(9095)
            ))
        );
    }

    // The cluster domain is optional; kubelet's search path supplies it.
    #[test]
    fn reads_a_reference_that_stops_at_svc() {
        assert!(refs("host: harbor-core.harbor.svc").contains(&(
            "harbor-core".into(),
            "harbor".into(),
            None
        )));
    }

    // A reference with no port is still a reference; the Service supplies the
    // number later.
    #[test]
    fn reads_a_reference_with_no_port() {
        assert!(
            refs("host: harbor-core.harbor.svc.cluster.local").contains(&(
                "harbor-core".into(),
                "harbor".into(),
                None
            ))
        );
    }

    // The short form also matches ordinary domain names. Nothing here can
    // tell them apart, which is why the caller keeps only what resolves
    // against the Service inventory.
    #[test]
    fn an_external_domain_looks_the_same_and_is_left_to_the_inventory() {
        let got = refs("proxy: yandex.net:443");
        assert!(got.contains(&("yandex".into(), "net".into(), Some(443))));
    }

    #[test]
    fn a_bare_word_is_not_a_reference() {
        assert!(refs("name: grafana").is_empty());
    }

    #[test]
    fn a_service_inventory_is_keyed_by_namespace_and_name() {
        let doc: Value = serde_yaml::from_str(
            "apiVersion: v1\nkind: Service\nmetadata: {name: loki, namespace: loki}\nspec: {ports: [{port: 3100}, {port: 9095}]}",
        )
        .unwrap();
        let r = K8sResource {
            api_version: "v1".into(),
            kind: "Service".into(),
            name: "loki".into(),
            namespace: Some("loki".into()),
            selector: None,
            pod_labels: None,
            configmap_refs: vec![],
            secret_refs: vec![],
            source_file: Default::default(),
            raw: doc,
            lint_skip: vec![],
        };
        let inv = service_inventory(&[r]);
        assert_eq!(
            inv.get(&("loki".to_string(), "loki".to_string())),
            Some(&[3100u32, 9095].into_iter().collect())
        );
    }

    fn policy(kind: &str, ns: &str, yaml: &str) -> K8sResource {
        K8sResource {
            api_version: "x".into(),
            kind: kind.into(),
            name: "p".into(),
            namespace: Some(ns.into()),
            selector: None,
            pod_labels: None,
            configmap_refs: vec![],
            secret_refs: vec![],
            source_file: Default::default(),
            raw: serde_yaml::from_str(yaml).unwrap(),
            lint_skip: vec![],
        }
    }

    #[test]
    fn an_egress_rule_permits_the_flow_it_names() {
        let p = policy(
            "NetworkPolicy",
            "grafana",
            "spec:\n  egress:\n    - to:\n        - namespaceSelector:\n            matchLabels:\n              kubernetes.io/metadata.name: loki\n      ports:\n        - port: 3100\n",
        );
        assert!(permitted(&[p]).contains(&Flow {
            from: "grafana".into(),
            to: "loki".into(),
            port: 3100
        }));
    }

    // An ingress rule describes the same flow from the other end, so it has
    // to land on the same pair rather than a reversed one.
    #[test]
    fn an_ingress_rule_permits_the_same_flow_read_backwards() {
        let p = policy(
            "NetworkPolicy",
            "loki",
            "spec:\n  ingress:\n    - from:\n        - namespaceSelector:\n            matchLabels:\n              kubernetes.io/metadata.name: grafana\n      ports:\n        - port: 3100\n",
        );
        assert!(permitted(&[p]).contains(&Flow {
            from: "grafana".into(),
            to: "loki".into(),
            port: 3100
        }));
    }

    #[test]
    fn cilium_policies_are_read_too() {
        let p = policy(
            "CiliumNetworkPolicy",
            "grafana",
            "spec:\n  egress:\n    - toEndpoints:\n        - matchLabels:\n            k8s:io.kubernetes.pod.namespace: loki\n      toPorts:\n        - ports:\n            - port: \"3100\"\n",
        );
        assert!(permitted(&[p]).contains(&Flow {
            from: "grafana".into(),
            to: "loki".into(),
            port: 3100
        }));
    }

    // `text_references` scans the document re-emitted as YAML, and a YAML
    // emitter is entitled to fold a long scalar across lines. A URL split in
    // half is a reference this stops seeing, and the missing policy for it
    // would then report as a pass.
    #[test]
    fn a_long_reference_survives_being_re_emitted() {
        let url = format!(
            "http://prometheus-kube-prometheus-prometheus.prometheus.svc.cluster.local:9090/{}",
            "a".repeat(120)
        );
        let doc: Value =
            serde_yaml::from_str(&format!("spec:\n  values:\n    remoteWrite: \"{url}\"\n"))
                .unwrap();
        let text = serde_yaml::to_string(&doc).unwrap();
        assert!(
            refs(&text).contains(&(
                "prometheus-kube-prometheus-prometheus".into(),
                "prometheus".into(),
                Some(9090)
            )),
            "reference lost when re-emitted:\n{text}"
        );
    }

    // A named port is the container's name for it, and nothing here can turn
    // that into a number. A rule whose ports are all named therefore permits
    // no flow this can see, which can only over-report ("no policy permits
    // it"), never under-report. Pinned so the trade-off is deliberate.
    #[test]
    fn a_named_port_is_invisible_to_the_analyser() {
        let p = policy(
            "NetworkPolicy",
            "grafana",
            "spec:\n  egress:\n    - to:\n        - namespaceSelector:\n            matchLabels:\n              kubernetes.io/metadata.name: loki\n      ports:\n        - port: metrics\n",
        );
        assert!(permitted(&[p]).is_empty());
    }

    // An ipBlock is off-cluster by construction, so it can never be what
    // satisfies a reference to a Service inside the cluster.
    #[test]
    fn an_ipblock_permits_no_in_cluster_flow() {
        let p = policy(
            "NetworkPolicy",
            "grafana",
            "spec:\n  egress:\n    - to:\n        - ipBlock:\n            cidr: 0.0.0.0/0\n      ports:\n        - port: 3100\n",
        );
        assert!(permitted(&[p]).is_empty());
    }
}

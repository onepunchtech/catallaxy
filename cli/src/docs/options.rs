use std::collections::{BTreeMap, HashMap};

use serde::Deserialize;

const CLUSTER_PREFIX: &str = "lab.clusters.<name>.";
const FLOE_PREFIX: &str = "lab.clusters.<name>.floes.";
const BUNDLES_PREFIX: &str = "lab.clusters.<name>.bundles.";
const LAB_STEPS_PREFIX: &str = "lab.steps.";
const BUNDLE_ENTRY_PREFIX: &str = "lab.clusters.<name>.bundles.<name>.";
const STEP_ENTRY_PREFIX: &str = "lab.steps.<name>.";

#[derive(Debug, Clone, Deserialize)]
pub struct OptionDoc {
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default, rename = "type")]
    pub type_name: Option<String>,
    #[serde(default)]
    pub default: Option<Literal>,
    #[serde(default)]
    pub example: Option<Literal>,
    #[serde(default)]
    pub declarations: Vec<Declaration>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum Literal {
    Rendered { text: String },
    Scalar(serde_json::Value),
}

impl Literal {
    pub fn text(&self) -> String {
        match self {
            Literal::Rendered { text } => text.clone(),
            Literal::Scalar(serde_json::Value::String(s)) => s.clone(),
            Literal::Scalar(v) => v.to_string(),
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum Declaration {
    Linked { name: String, url: String },
    Plain(String),
}

#[derive(Debug, PartialEq, Eq)]
pub enum Route {
    Lab,
    LabSteps,
    Cluster,
    ClusterBundles,
    Floe(String),
}

pub fn route(name: &str) -> Option<Route> {
    if let Some(rest) = name.strip_prefix(FLOE_PREFIX) {
        return Some(Route::Floe(
            rest.split('.').next().unwrap_or_default().to_string(),
        ));
    }
    if name.starts_with(BUNDLES_PREFIX) {
        return Some(Route::ClusterBundles);
    }
    if name.starts_with(CLUSTER_PREFIX) {
        return Some(Route::Cluster);
    }
    if name.starts_with(LAB_STEPS_PREFIX) {
        return Some(Route::LabSteps);
    }
    if name.starts_with("lab.") {
        return Some(Route::Lab);
    }
    None
}

pub fn escape_placeholders(text: &str) -> String {
    text.split('`')
        .enumerate()
        .map(|(i, part)| {
            if i % 2 == 0 {
                part.replace('<', "&lt;").replace('>', "&gt;")
            } else {
                part.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("`")
}

fn block_or_inline(label: &str, text: &str) -> String {
    if text.len() > 80 || text.contains('\n') {
        format!("**{label}:**\n```nix\n{text}\n```\n")
    } else {
        format!("**{label}:** `{text}`\n")
    }
}

pub fn anchor(display_name: &str) -> String {
    display_name
        .to_lowercase()
        .split(['.', ' '])
        .map(|seg| {
            seg.trim_matches(|c| c == '<' || c == '>' || c == '*')
                .to_string()
        })
        .filter(|seg| !seg.is_empty())
        .collect::<Vec<_>>()
        .join("-")
}

fn group_of(display_name: &str) -> &str {
    match display_name.split_once('.') {
        Some((head, _)) => head,
        None => "",
    }
}

pub fn render_option(name: &str, opt: &OptionDoc) -> String {
    let mut lines: Vec<String> = vec![format!("### `{name}` {{#{}}}\n", anchor(name))];

    if let Some(d) = opt.description.as_ref().filter(|d| !d.trim().is_empty()) {
        lines.push(escape_placeholders(d.trim()));
        lines.push(String::new());
    }

    if let Some(t) = opt.type_name.as_ref().filter(|t| !t.is_empty()) {
        lines.push(format!("**Type:** `{t}`\n"));
    }

    if let Some(default) = &opt.default {
        let text = default.text();
        if !text.is_empty() && text != "null" {
            lines.push(block_or_inline("Default", &text));
        }
    }

    if let Some(example) = &opt.example {
        let text = example.text();
        if !text.is_empty() {
            lines.push(block_or_inline("Example", &text));
        }
    }

    let links: Vec<String> = opt
        .declarations
        .iter()
        .map(|d| match d {
            Declaration::Linked { name, url } => format!("[{name}]({url})"),
            Declaration::Plain(s) => s.clone(),
        })
        .collect();
    if !links.is_empty() {
        lines.push(format!("**Declared in:** {}\n", links.join(", ")));
    }

    lines.push("---\n".to_string());
    lines.join("\n")
}

fn render_index(displayed: &[(String, &OptionDoc)]) -> String {
    let mut out = String::from("| Option | Type | Default |\n| --- | --- | --- |\n");
    for (display, opt) in displayed {
        let ty = opt.type_name.clone().unwrap_or_default();
        let default = opt
            .default
            .as_ref()
            .map(|d| d.text())
            .filter(|t| !t.is_empty() && !t.contains('\n') && t.len() <= 40)
            .map(|t| format!("`{t}`"))
            .unwrap_or_default();
        out.push_str(&format!(
            "| [`{display}`](#{}) | `{ty}` | {default} |\n",
            anchor(display)
        ));
    }
    out.push('\n');
    out
}

pub fn render_page(
    title: &str,
    description: &str,
    options: &BTreeMap<String, OptionDoc>,
    prefix_to_strip: &str,
) -> Result<String, String> {
    let mut out = format!("# {title}\n\n");
    if !description.is_empty() {
        out.push_str(&format!("{description}\n\n"));
    }
    if options.is_empty() {
        out.push_str("No options in this category.\n");
        return Ok(out);
    }

    let mut displayed: Vec<(String, &OptionDoc)> = options
        .iter()
        .map(|(name, opt)| {
            (
                name.strip_prefix(prefix_to_strip)
                    .unwrap_or(name)
                    .to_string(),
                opt,
            )
        })
        .collect();

    displayed.sort_by(|(a, _), (b, _)| group_of(a).cmp(group_of(b)).then_with(|| a.cmp(b)));

    let mut seen: HashMap<String, String> = HashMap::new();
    for (display, _) in &displayed {
        let a = anchor(display);
        if let Some(previous) = seen.insert(a.clone(), display.clone()) {
            return Err(format!(
                "anchor `#{a}` is claimed by both `{previous}` and `{display}` on page \"{title}\""
            ));
        }
    }

    out.push_str(&render_index(&displayed));

    let mut current_group: Option<&str> = None;
    for (display, opt) in &displayed {
        let group = group_of(display);
        if current_group != Some(group) {
            out.push_str(&format!(
                "## {}\n\n",
                if group.is_empty() {
                    "Top level".to_string()
                } else {
                    format!("`{group}`")
                }
            ));
            current_group = Some(group);
        }
        out.push_str(&render_option(display, opt));
    }
    Ok(out)
}

pub fn render_floe_index(floe_names: &[String]) -> String {
    let mut out = String::from("# Floe Options\n\n");
    out.push_str(
        "One page per built-in floe. Every option below is set inside a\n\
         `lab.clusters.<name>` submodule, under `floes.<floe>.`\n\n",
    );
    for name in floe_names {
        out.push_str(&format!("- [`floes.{name}`](./{name}.md)\n"));
    }
    out
}

#[derive(Debug)]
pub struct Page {
    pub path: String,
    pub body: String,
}

#[derive(Debug)]
pub enum RenderError {
    Unrouted(Vec<String>),
    AnchorCollision(String),
}

#[derive(Debug)]
pub struct Rendered {
    pub pages: Vec<Page>,
    pub option_count: usize,
    pub undescribed: Vec<String>,
}

pub fn is_undescribed(opt: &OptionDoc) -> bool {
    opt.description
        .as_ref()
        .is_none_or(|d| d.trim().is_empty() || d.trim() == "This option has no description.")
}

pub fn render_all(all: BTreeMap<String, OptionDoc>) -> Result<Rendered, RenderError> {
    let mut lab = BTreeMap::new();
    let mut lab_steps = BTreeMap::new();
    let mut cluster = BTreeMap::new();
    let mut bundles = BTreeMap::new();
    let mut floes: BTreeMap<String, BTreeMap<String, OptionDoc>> = BTreeMap::new();
    let mut unrouted = Vec::new();
    let mut undescribed = Vec::new();

    for (name, opt) in all {
        if name == "_module.args" {
            continue;
        }
        if is_undescribed(&opt) {
            undescribed.push(name.clone());
        }
        match route(&name) {
            Some(Route::Floe(floe)) => {
                floes.entry(floe).or_default().insert(name, opt);
            }
            Some(Route::ClusterBundles) => {
                bundles.insert(name, opt);
            }
            Some(Route::Cluster) => {
                cluster.insert(name, opt);
            }
            Some(Route::LabSteps) => {
                lab_steps.insert(name, opt);
            }
            Some(Route::Lab) => {
                lab.insert(name, opt);
            }
            None => unrouted.push(name),
        }
    }

    if !unrouted.is_empty() {
        unrouted.sort();
        return Err(RenderError::Unrouted(unrouted));
    }

    let option_count = lab.len()
        + lab_steps.len()
        + cluster.len()
        + bundles.len()
        + floes.values().map(|f| f.len()).sum::<usize>();
    assemble_pages(
        lab,
        lab_steps,
        cluster,
        bundles,
        floes,
        option_count,
        undescribed,
    )
}

type OptionMap = BTreeMap<String, OptionDoc>;

fn assemble_pages(
    lab: OptionMap,
    lab_steps: OptionMap,
    cluster: OptionMap,
    bundles: OptionMap,
    floes: BTreeMap<String, OptionMap>,
    option_count: usize,
    mut undescribed: Vec<String>,
) -> Result<Rendered, RenderError> {
    let mut pages = vec![
        Page {
            path: "options/lab.md".into(),
            body: render_page(
                "Lab Options",
                "Lab-scope options: identity, CD strategy, DNS, networking, secrets, \
                 images, lint, plan steps, and operations.",
                &lab,
                "lab.",
            )
            .map_err(RenderError::AnchorCollision)?,
        },
        Page {
            path: "options/cluster.md".into(),
            body: render_page(
                "Cluster Options",
                "Options for an individual cluster within a lab: Kubernetes settings, \
                 provisioners, phases, bundles, secrets projections, drift, lifecycle \
                 hooks, and authentication.\n\nAll options are under `lab.clusters.<name>.`",
                &cluster,
                CLUSTER_PREFIX,
            )
            .map_err(RenderError::AnchorCollision)?,
        },
        Page {
            path: "options/steps.md".into(),
            body: render_page(
                "Plan Step Options",
                "Steps you declare yourself, at `lab.steps.<name>`. What each `kind` \
                 accepts in `params` is in [Plan Step Kinds](../step-kinds.md).",
                &lab_steps,
                STEP_ENTRY_PREFIX,
            )
            .map_err(RenderError::AnchorCollision)?,
        },
        Page {
            path: "options/bundles.md".into(),
            body: render_page(
                "Bundle Options",
                "One installable group of Kubernetes resources, at \
                 `lab.clusters.<name>.bundles.<name>`. The judgement calls are in \
                 [Writing a Bundle](../bundles.md).",
                &bundles,
                BUNDLE_ENTRY_PREFIX,
            )
            .map_err(RenderError::AnchorCollision)?,
        },
    ];

    for (floe, options) in &floes {
        pages.push(Page {
            path: format!("options/floes/{floe}.md"),
            body: render_page(
                &format!("`floes.{floe}` Options"),
                &format!("All options are under `lab.clusters.<name>.floes.{floe}.`"),
                options,
                FLOE_PREFIX,
            )
            .map_err(RenderError::AnchorCollision)?,
        });
    }

    let names: Vec<String> = floes.keys().cloned().collect();
    pages.push(Page {
        path: "options/floes/index.md".into(),
        body: render_floe_index(&names),
    });

    undescribed.sort();

    Ok(Rendered {
        pages,
        option_count,
        undescribed,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn opt(description: &str) -> OptionDoc {
        OptionDoc {
            description: Some(description.to_string()),
            type_name: Some("bool".into()),
            default: None,
            example: None,
            declarations: vec![],
        }
    }

    #[test]
    fn routes_floe_options_to_their_own_page() {
        assert_eq!(
            route("lab.clusters.<name>.floes.kanidm.domain"),
            Some(Route::Floe("kanidm".into()))
        );
        assert_eq!(
            route("lab.clusters.<name>.kubernetes.version"),
            Some(Route::Cluster)
        );
        assert_eq!(route("lab.name"), Some(Route::Lab));
        assert_eq!(route("nixpkgs.config"), None);
    }

    #[test]
    fn placeholders_are_escaped_only_outside_code_spans() {
        assert_eq!(
            escape_placeholders("set `floes.<n>.x` on <name> here"),
            "set `floes.<n>.x` on &lt;name&gt; here"
        );
    }

    #[test]
    fn long_defaults_become_code_blocks() {
        let inline = block_or_inline("Default", "true");
        assert_eq!(inline, "**Default:** `true`\n");
        let block = block_or_inline("Default", &"x".repeat(81));
        assert!(block.starts_with("**Default:**\n```nix\n"));
    }

    #[test]
    fn a_multiline_default_becomes_a_code_block_even_when_short() {
        assert!(block_or_inline("Example", "a\nb").contains("```nix"));
    }

    #[test]
    fn unrouted_options_are_an_error_not_a_silent_drop() {
        let mut all = BTreeMap::new();
        all.insert("nixpkgs.config".to_string(), opt("stray"));
        match render_all(all).unwrap_err() {
            RenderError::Unrouted(names) => assert_eq!(names, vec!["nixpkgs.config".to_string()]),
            other => panic!("expected Unrouted, got {other:?}"),
        }
    }

    #[test]
    fn bundles_and_steps_route_to_their_own_pages() {
        assert_eq!(
            route("lab.clusters.<name>.bundles.<name>.after"),
            Some(Route::ClusterBundles)
        );
        assert_eq!(route("lab.steps.<name>.kind"), Some(Route::LabSteps));
    }

    #[test]
    fn the_parent_bundles_option_stays_on_the_cluster_page() {
        assert_eq!(
            route("lab.clusters.<name>.bundles"),
            Some(Route::Cluster),
            "the parent carries the pointer description and belongs with the cluster"
        );
        assert_eq!(route("lab.steps"), Some(Route::Lab));
    }

    #[test]
    fn a_floe_still_wins_over_the_cluster_prefix() {
        assert_eq!(
            route("lab.clusters.<name>.floes.gateway.tls"),
            Some(Route::Floe("gateway".into()))
        );
    }

    #[test]
    fn anchors_strip_placeholder_punctuation() {
        assert_eq!(anchor("helmCharts.<name>.values"), "helmcharts-name-values");
        assert_eq!(anchor("assertions.*.message"), "assertions-message");
        assert_eq!(anchor("awaitRollout"), "awaitrollout");
    }

    #[test]
    fn an_option_heading_carries_its_anchor() {
        let rendered = render_option("awaitRollout", &opt("wait for it"));
        assert!(rendered.starts_with("### `awaitRollout` {#awaitrollout}"));
    }

    #[test]
    fn colliding_anchors_are_an_error_not_a_silent_shadow() {
        let mut options = BTreeMap::new();
        options.insert("a.<name>.x".to_string(), opt("one"));
        options.insert("a.name.x".to_string(), opt("two"));
        let err = render_page("T", "", &options, "").unwrap_err();
        assert!(err.contains("a-name-x"), "{err}");
        assert!(
            err.contains("a.<name>.x") && err.contains("a.name.x"),
            "{err}"
        );
    }

    #[test]
    fn a_page_leads_with_an_index_table_then_groups() {
        let mut options = BTreeMap::new();
        options.insert("dns.zone".to_string(), opt("the zone"));
        options.insert("dns.enable".to_string(), opt("on"));
        options.insert("name".to_string(), opt("lab name"));
        let page = render_page("T", "", &options, "").unwrap();

        assert!(page.contains("| Option | Type | Default |"));
        assert!(page.contains("| [`dns.zone`](#dns-zone) |"));
        assert!(page.contains("## Top level"));
        assert!(page.contains("## `dns`"));
        assert!(
            page.find("## Top level") < page.find("## `dns`"),
            "groups must be contiguous and sorted"
        );
    }

    #[test]
    fn undescribed_options_are_collected() {
        let mut all = BTreeMap::new();
        all.insert("lab.described".to_string(), opt("has one"));
        all.insert("lab.bare".to_string(), opt(""));
        let rendered = render_all(all).unwrap();
        assert_eq!(rendered.undescribed, vec!["lab.bare".to_string()]);
    }

    #[test]
    fn module_args_is_dropped_without_being_unrouted() {
        let mut all = BTreeMap::new();
        all.insert("_module.args".to_string(), opt("internal"));
        all.insert("lab.name".to_string(), opt("the lab"));
        let rendered = render_all(all).expect("routes cleanly");
        assert_eq!(rendered.option_count, 1);
    }

    #[test]
    fn every_floe_gets_a_page_and_an_index_entry() {
        let mut all = BTreeMap::new();
        all.insert(
            "lab.clusters.<name>.floes.kanidm.domain".to_string(),
            opt("d"),
        );
        all.insert(
            "lab.clusters.<name>.floes.netbird.domain".to_string(),
            opt("d"),
        );
        let rendered = render_all(all).expect("routes cleanly");
        let paths: Vec<&str> = rendered.pages.iter().map(|p| p.path.as_str()).collect();
        assert!(paths.contains(&"options/floes/kanidm.md"));
        assert!(paths.contains(&"options/floes/netbird.md"));
        let index = rendered
            .pages
            .iter()
            .find(|p| p.path == "options/floes/index.md")
            .unwrap();
        assert!(index.body.contains("[`floes.kanidm`](./kanidm.md)"));
        assert!(index.body.contains("[`floes.netbird`](./netbird.md)"));
    }

    #[test]
    fn option_names_are_shown_with_their_page_prefix_stripped() {
        let mut all = BTreeMap::new();
        all.insert(
            "lab.clusters.<name>.floes.kanidm.domain".to_string(),
            opt("d"),
        );
        let rendered = render_all(all).expect("routes cleanly");
        let page = rendered
            .pages
            .iter()
            .find(|p| p.path == "options/floes/kanidm.md")
            .unwrap();
        assert!(page.body.contains("## `kanidm.domain`"));
    }
}

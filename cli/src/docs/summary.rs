pub struct NavEntry {
    pub section: Option<String>,
    pub title: String,
    pub path: String,
}

pub fn parse(summary: &str) -> Vec<NavEntry> {
    let mut section: Option<String> = None;
    let mut out = Vec::new();

    for line in summary.lines() {
        let trimmed = line.trim();
        if let Some(heading) = trimmed.strip_prefix("# ") {
            if !trimmed.contains("](") {
                let heading = heading.trim();
                section = if heading == "Summary" {
                    None
                } else {
                    Some(heading.to_string())
                };
                continue;
            }
        }
        if let Some((title, path)) = parse_link(line) {
            out.push(NavEntry {
                section: section.clone(),
                title,
                path,
            });
        }
    }
    out
}

fn parse_link(line: &str) -> Option<(String, String)> {
    let rest = line.trim_start();
    let rest = rest
        .strip_prefix("- ")
        .or_else(|| rest.strip_prefix("* "))
        .unwrap_or(rest)
        .trim_start();
    let rest = rest.strip_prefix('[')?;
    let (title, rest) = rest.split_once("](")?;
    let (target, _) = rest.split_once(')')?;
    let path = target.strip_prefix("./")?;
    if !path.ends_with(".md") {
        return None;
    }
    Some((title.to_string(), path.to_string()))
}

const OPTIONS_ANCHOR: &str = "](./reference/options.md)";
const CLI_ANCHOR: &str = "](./reference/cli.md)";

fn nav_line(page: &str) -> Option<String> {
    let link = format!("./reference/{page}");
    let entry = |indent: &str, title: &str| Some(format!("{indent}- [{title}]({link})"));
    match page {
        "options/lab.md" => entry("  ", "lab.*"),
        "options/steps.md" => entry("    ", "lab.steps.*"),
        "options/cluster.md" => entry("  ", "cluster.*"),
        "options/bundles.md" => entry("    ", "bundles.*"),
        "options/floes/index.md" => entry("  ", "floes.*"),
        "cli/commands.md" => entry("  ", "Commands"),
        _ => {
            let floe = page.strip_prefix("options/floes/")?.strip_suffix(".md")?;
            entry("    ", floe)
        }
    }
}

pub fn nav_block(pages: &[String]) -> Vec<String> {
    let rank = |page: &str| match page {
        "options/lab.md" => 0,
        "options/steps.md" => 1,
        "options/cluster.md" => 2,
        "options/bundles.md" => 3,
        "options/floes/index.md" => 4,
        _ => 5,
    };
    let mut ordered: Vec<&String> = pages.iter().collect();
    ordered.sort_by(|a, b| rank(a).cmp(&rank(b)).then_with(|| a.cmp(b)));
    ordered.iter().filter_map(|p| nav_line(p)).collect()
}

pub fn splice_nav(summary: &str, pages: &[String]) -> String {
    let mut out: Vec<String> = Vec::new();
    let mut lines = summary.lines().peekable();

    while let Some(line) = lines.next() {
        out.push(line.to_string());
        let under: Vec<String> = if line.contains(OPTIONS_ANCHOR) {
            pages
                .iter()
                .filter(|p| p.starts_with("options/"))
                .cloned()
                .collect()
        } else if line.contains(CLI_ANCHOR) {
            pages
                .iter()
                .filter(|p| p.starts_with("cli/"))
                .cloned()
                .collect()
        } else {
            continue;
        };
        while lines
            .peek()
            .is_some_and(|next| next.starts_with(' ') && !next.trim().is_empty())
        {
            lines.next();
        }
        out.extend(nav_block(&under));
    }

    let mut joined = out.join("\n");
    if summary.ends_with('\n') {
        joined.push('\n');
    }
    joined
}

#[cfg(test)]
mod tests {
    use super::*;

    const SUMMARY: &str = "# Summary\n\n# Reference\n\n- [CLI](./reference/cli.md)\n- [Module Options](./reference/options.md)\n  - [lab.*](./reference/options/lab.md)\n    - [stale](./reference/options/floes/stale.md)\n- [Glossary](./reference/glossary.md)\n";

    fn pages() -> Vec<String> {
        [
            "options/lab.md",
            "options/cluster.md",
            "options/floes/index.md",
            "options/floes/argocd.md",
            "options/floes/kanidm.md",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect()
    }

    #[test]
    fn sections_come_from_unlinked_headings() {
        let entries = parse(SUMMARY);
        assert_eq!(entries[0].section.as_deref(), Some("Reference"));
        assert_eq!(entries[0].title, "CLI");
    }

    #[test]
    fn the_summary_title_is_not_a_section() {
        let entries = parse("# Summary\n\n- [A](./a.md)\n");
        assert_eq!(entries[0].section, None);
    }

    #[test]
    fn floes_are_nested_one_level_deeper_than_the_top_three() {
        let block = nav_block(&pages());
        assert_eq!(block[0], "  - [lab.*](./reference/options/lab.md)");
        assert_eq!(
            block[2],
            "  - [floes.*](./reference/options/floes/index.md)"
        );
        assert_eq!(
            block[3],
            "    - [argocd](./reference/options/floes/argocd.md)"
        );
    }

    #[test]
    fn splice_replaces_the_whole_generated_subtree() {
        let out = splice_nav(SUMMARY, &pages());
        assert!(!out.contains("stale.md"), "the old subtree must be gone");
        assert!(out.contains("    - [kanidm](./reference/options/floes/kanidm.md)"));
    }

    #[test]
    fn splice_preserves_everything_outside_the_subtree() {
        let out = splice_nav(SUMMARY, &pages());
        assert!(out.contains("- [CLI](./reference/cli.md)"));
        assert!(out.contains("- [Glossary](./reference/glossary.md)"));
        assert!(out.contains("- [Module Options](./reference/options.md)"));
        assert!(out.ends_with('\n'));
    }

    #[test]
    fn the_cli_subtree_splices_under_its_own_anchor() {
        let mut all = pages();
        all.push("cli/commands.md".to_string());
        let out = splice_nav(SUMMARY, &all);
        assert!(
            out.contains(
                "- [CLI](./reference/cli.md)\n  - [Commands](./reference/cli/commands.md)"
            )
        );
        assert!(
            !out.contains("  - [Commands](./reference/cli/commands.md)\n  - [lab.*]"),
            "cli pages must not leak into the options subtree"
        );
    }

    #[test]
    fn splice_is_idempotent() {
        let once = splice_nav(SUMMARY, &pages());
        assert_eq!(splice_nav(&once, &pages()), once);
    }
}

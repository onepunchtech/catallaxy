use crate::docs::summary::NavEntry;

pub struct Page<'a> {
    pub entry: &'a NavEntry,
    pub body: String,
}

pub struct LlmsOutput {
    pub index: String,
    pub full: String,
    pub indexed: usize,
    pub omitted: usize,
}

pub fn first_paragraph(body: &str) -> String {
    let mut out: Vec<&str> = Vec::new();
    for line in body.lines() {
        if line.starts_with("# ") || line.starts_with('>') {
            continue;
        }
        if line.trim().is_empty() {
            if !out.is_empty() {
                break;
            }
            continue;
        }
        if line.starts_with("```") || line.starts_with('|') {
            break;
        }
        out.push(line.trim());
    }
    out.join(" ")
}

pub fn render(pages: &[Page<'_>], omitted: usize, base_url: &str) -> LlmsOutput {
    let base_url = base_url.trim_end_matches('/');

    let mut index: Vec<String> = vec![
        "# Catallaxy".into(),
        String::new(),
        "> Declarative Kubernetes platform management. A lab is a typed,".into(),
        "> ordered graph of modules -- clusters, the capabilities running on".into(),
        "> them, and the plan that builds them -- expressed in the Nix module".into(),
        "> system and executed by a Rust CLI.".into(),
        String::new(),
        "The unit of platform is a *floe*: a self-contained module with an".into(),
        "option surface, the manifests it emits, and a typed interface other".into(),
        "floes read. Install order is derived from declared dependencies".into(),
        "rather than assigned numbers.".into(),
        String::new(),
    ];

    let mut full: Vec<String> = vec![
        "# Catallaxy documentation".into(),
        String::new(),
        "Full text in navigation order. Generated from the book; do not edit.".into(),
        "Per-floe option references are omitted -- fetch them individually".into(),
        format!("from {base_url}/reference/options/floes/<floe>.html"),
        String::new(),
    ];

    let mut current: Option<String> = None;
    let mut first = true;

    for page in pages {
        let rel = &page.entry.path;
        let url = format!("{base_url}/{}.html", rel.trim_end_matches(".md"));

        if first || page.entry.section != current {
            index.push(String::new());
            index.push(format!(
                "## {}",
                page.entry.section.as_deref().unwrap_or("Overview")
            ));
            index.push(String::new());
            current = page.entry.section.clone();
            first = false;
        }

        let summary = first_paragraph(&page.body);
        index.push(if summary.is_empty() {
            format!("- [{}]({url})", page.entry.title)
        } else {
            format!("- [{}]({url}): {summary}", page.entry.title)
        });

        full.push(format!(
            "\n\n{}\n# {}\nSource: {url}\n{}\n",
            "=".repeat(72),
            page.entry.title,
            "=".repeat(72)
        ));
        full.push(
            page.body
                .lines()
                .filter(|l| !l.starts_with("> **Status:**"))
                .collect::<Vec<_>>()
                .join("\n"),
        );
    }

    index.extend([
        String::new(),
        "## Source".into(),
        String::new(),
        "- Repository: https://github.com/onepunchtech/catallaxy".into(),
        format!("- Full text: {base_url}/llms-full.txt"),
        format!("- Generated option reference: {base_url}/reference/options/"),
    ]);

    LlmsOutput {
        index: index.join("\n") + "\n",
        full: full.join("\n") + "\n",
        indexed: pages.len(),
        omitted,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(section: Option<&str>, title: &str, path: &str) -> NavEntry {
        NavEntry {
            section: section.map(str::to_string),
            title: title.to_string(),
            path: path.to_string(),
        }
    }

    #[test]
    fn first_paragraph_skips_the_heading_and_admonitions() {
        let body =
            "# Title\n\n> **Status:** draft\n\nThe real opening line.\nSecond line.\n\nLater.";
        assert_eq!(first_paragraph(body), "The real opening line. Second line.");
    }

    #[test]
    fn first_paragraph_stops_at_a_code_fence() {
        assert_eq!(first_paragraph("# T\n\n```nix\nx\n```"), "");
        assert_eq!(first_paragraph("# T\n\nProse\n```nix\nx\n```"), "Prose");
    }

    #[test]
    fn first_paragraph_stops_at_a_table() {
        assert_eq!(first_paragraph("# T\n\n| a | b |\n"), "");
    }

    #[test]
    fn index_groups_pages_under_their_section() {
        let a = entry(Some("Guide"), "One", "guide/one.md");
        let b = entry(Some("Guide"), "Two", "guide/two.md");
        let c = entry(Some("Reference"), "Three", "ref/three.md");
        let pages = vec![
            Page {
                entry: &a,
                body: "# One\n\nFirst.".into(),
            },
            Page {
                entry: &b,
                body: "# Two\n\nSecond.".into(),
            },
            Page {
                entry: &c,
                body: "# Three\n\nThird.".into(),
            },
        ];
        let out = render(&pages, 4, "https://example.com/");
        assert_eq!(out.indexed, 3);
        assert_eq!(out.omitted, 4);
        assert_eq!(out.index.matches("## Guide").count(), 1);
        assert_eq!(out.index.matches("## Reference").count(), 1);
        assert!(
            out.index
                .contains("- [One](https://example.com/guide/one.html): First.")
        );
    }

    #[test]
    fn a_page_with_no_prose_still_gets_a_link() {
        let a = entry(None, "Bare", "bare.md");
        let pages = vec![Page {
            entry: &a,
            body: "# Bare\n".into(),
        }];
        let out = render(&pages, 0, "https://example.com");
        assert!(
            out.index
                .contains("- [Bare](https://example.com/bare.html)\n")
        );
        assert!(out.index.contains("## Overview"));
    }

    #[test]
    fn full_text_drops_status_admonitions_but_keeps_the_body() {
        let a = entry(None, "P", "p.md");
        let pages = vec![Page {
            entry: &a,
            body: "# P\n> **Status:** wip\nkept line".into(),
        }];
        let out = render(&pages, 0, "https://example.com");
        assert!(!out.full.contains("**Status:**"));
        assert!(out.full.contains("kept line"));
    }
}

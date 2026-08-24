//! Everything that spawns a process, touches the filesystem, opens a socket or
//! reads the environment belongs in `cli/src/io`. The rest of the tree stays
//! testable without a cluster, a daemon or a home directory.
//!
//! This replaces `nix/checks/cli-io-scan.py`, which replaced an awk extractor
//! before it. Both were lexical, and the difficulty in both was the same:
//! finding test modules, which are exempt because a test may reach for a real
//! temp directory.
//!
//! The awk version was `awk '/^#\[cfg\(test\)\]/ { exit }'` — it stopped at
//! the first match and treated the attribute on *any* item as the start of
//! tests, so a conditional `#[cfg(test)] use std::io::Read;` on line 2 of
//! `host/services.rs` exempted all 422 lines of it. The Python version walked
//! lines, tracked brace depth and blanked out string literals and comments so
//! the braces inside them would not be counted.
//!
//! Both were reconstructing the item tree. `syn` has it: `#[cfg(test)]` is an
//! attribute on an item, and the item's extent is the item. There is no brace
//! counting, no literal stripping, and no way for a `}` inside a raw string to
//! move a boundary.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use syn::spanned::Spanned;
use syn::visit::Visit;

/// How much of a path a rule has to see before it counts.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Reach {
    /// The rule itself is already I/O, as is anything under it. `use std::fs;`
    /// counts even though nothing is called on that line.
    OrDeeper,
    /// Only something *under* the rule is I/O. Naming the type is not.
    DeeperOnly,
}

/// I/O this tree keeps behind `cli/src/io`, and why each one matters.
const FORBIDDEN: &[(&str, &str, Reach)] = &[
    ("std::process::Command", "spawns a process", Reach::OrDeeper),
    (
        "std::process::exit",
        "exits without unwinding, so Drop never runs",
        Reach::OrDeeper,
    ),
    ("std::fs", "touches the filesystem", Reach::OrDeeper),
    ("std::env::var", "reads the environment", Reach::OrDeeper),
    (
        "tempfile",
        "creates files outside the io seam",
        Reach::OrDeeper,
    ),
    ("std::net", "opens a socket", Reach::OrDeeper),
    // Holding a `&reqwest::Client` someone else built is not a request;
    // `reqwest::Client::new()` is. A rule that matched the bare type flagged
    // every function that merely takes one as an argument.
    (
        "reqwest::Client",
        "makes an HTTP request",
        Reach::DeeperOnly,
    ),
    ("reqwest::get", "makes an HTTP request", Reach::OrDeeper),
    ("which::which", "searches PATH", Reach::OrDeeper),
];

/// Why this path is I/O, if it is.
///
/// A rule matches at a segment boundary, so `std::fs` catches
/// `std::fs::read_to_string` without also catching a `std::fsync`-shaped name.
fn reason_for(path: &str) -> Option<&'static str> {
    FORBIDDEN.iter().find_map(|(rule, why, reach)| {
        let deeper = path.starts_with(&format!("{rule}::"));
        let matches = deeper || (*reach == Reach::OrDeeper && path == *rule);
        matches.then_some(*why)
    })
}

/// Ordered by file then line *numerically*. Sorting the `path:line` string
/// instead puts line 15 before line 6.
#[derive(Debug, PartialEq, Eq, PartialOrd, Ord)]
struct Finding {
    file: String,
    line: usize,
    why: &'static str,
}

impl Finding {
    fn key(&self) -> String {
        format!("{}:{}", self.file, self.line)
    }
}

/// Collects I/O paths, skipping anything under `#[cfg(test)]`.
struct Scan {
    findings: Vec<Finding>,
    relative: String,
}

/// Whether an item is compiled only for tests.
fn is_cfg_test(attrs: &[syn::Attribute]) -> bool {
    attrs.iter().any(|attr| {
        if !attr.path().is_ident("cfg") {
            return false;
        }
        let mut test = false;
        let _ = attr.parse_nested_meta(|meta| {
            if meta.path.is_ident("test") {
                test = true;
            }
            Ok(())
        });
        test
    })
}

fn item_attrs(item: &syn::Item) -> &[syn::Attribute] {
    match item {
        syn::Item::Const(i) => &i.attrs,
        syn::Item::Enum(i) => &i.attrs,
        syn::Item::ExternCrate(i) => &i.attrs,
        syn::Item::Fn(i) => &i.attrs,
        syn::Item::ForeignMod(i) => &i.attrs,
        syn::Item::Impl(i) => &i.attrs,
        syn::Item::Macro(i) => &i.attrs,
        syn::Item::Mod(i) => &i.attrs,
        syn::Item::Static(i) => &i.attrs,
        syn::Item::Struct(i) => &i.attrs,
        syn::Item::Trait(i) => &i.attrs,
        syn::Item::TraitAlias(i) => &i.attrs,
        syn::Item::Type(i) => &i.attrs,
        syn::Item::Union(i) => &i.attrs,
        syn::Item::Use(i) => &i.attrs,
        _ => &[],
    }
}

impl Scan {
    fn record(&mut self, path: &str, span: proc_macro2::Span) {
        if let Some(why) = reason_for(path) {
            self.findings.push(Finding {
                file: self.relative.clone(),
                line: span.start().line,
                why,
            });
        }
    }
}

impl Visit<'_> for Scan {
    fn visit_item(&mut self, item: &syn::Item) {
        // The whole point: a test item is skipped entirely, and its extent is
        // decided by the parser rather than by counting braces.
        if is_cfg_test(item_attrs(item)) {
            return;
        }
        syn::visit::visit_item(self, item);
    }

    fn visit_path(&mut self, path: &syn::Path) {
        let text = path
            .segments
            .iter()
            .map(|s| s.ident.to_string())
            .collect::<Vec<_>>()
            .join("::");
        self.record(&text, path.span());
        syn::visit::visit_path(self, path);
    }

    fn visit_item_use(&mut self, item: &syn::ItemUse) {
        if is_cfg_test(&item.attrs) {
            return;
        }
        let mut prefix = Vec::new();
        self.walk_use(&item.tree, &mut prefix, item.span());
    }
}

impl Scan {
    fn walk_use(&mut self, tree: &syn::UseTree, prefix: &mut Vec<String>, span: proc_macro2::Span) {
        match tree {
            syn::UseTree::Path(p) => {
                prefix.push(p.ident.to_string());
                self.walk_use(&p.tree, prefix, span);
                prefix.pop();
            }
            syn::UseTree::Name(n) => {
                prefix.push(n.ident.to_string());
                self.record(&prefix.join("::"), span);
                prefix.pop();
            }
            syn::UseTree::Rename(r) => {
                prefix.push(r.ident.to_string());
                self.record(&prefix.join("::"), span);
                prefix.pop();
            }
            syn::UseTree::Glob(_) => {
                self.record(&prefix.join("::"), span);
            }
            syn::UseTree::Group(g) => {
                for item in &g.items {
                    self.walk_use(item, prefix, span);
                }
            }
        }
    }
}

fn scan_tree(root: &Path) -> Vec<Finding> {
    let mut findings = Vec::new();

    for entry in walkdir::WalkDir::new(root)
        .sort_by_file_name()
        .into_iter()
        .filter_map(Result::ok)
    {
        let path = entry.path();
        if path.extension().is_none_or(|e| e != "rs") {
            continue;
        }

        let relative = path
            .strip_prefix(root)
            .unwrap_or(path)
            .display()
            .to_string();

        // io/ is where this all belongs.
        if relative.starts_with("io/") || relative.contains("/io/") {
            continue;
        }

        let text = std::fs::read_to_string(path)
            .unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
        let parsed =
            syn::parse_file(&text).unwrap_or_else(|e| panic!("parsing {}: {e}", path.display()));

        let mut scan = Scan {
            findings: Vec::new(),
            relative,
        };
        scan.visit_file(&parsed);
        findings.extend(scan.findings);
    }

    findings.sort();
    findings.dedup_by(|a, b| a.file == b.file && a.line == b.line);
    findings
}

fn baseline() -> BTreeSet<String> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("io-baseline.txt");
    std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("reading {}: {e}", path.display()))
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(ToOwned::to_owned)
        .collect()
}

/// I/O outside `cli/src/io` is fixed, or listed in the baseline.
///
/// The baseline can only shrink: an entry that no longer fires is an error
/// too, because a baseline that outlives its debt stops being a ratchet and
/// starts being an excuse list.
#[test]
fn io_stays_in_io() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src");
    let findings = scan_tree(&root);

    assert!(
        !findings.is_empty(),
        "the scanner found no I/O anywhere, which cannot be right; it is not \
         reading the tree"
    );

    let allowed = baseline();
    let seen: BTreeSet<String> = findings.iter().map(Finding::key).collect();

    let new: Vec<&Finding> = findings
        .iter()
        .filter(|f| !allowed.contains(&f.key()))
        .collect();
    let stale: Vec<&String> = allowed.iter().filter(|b| !seen.contains(*b)).collect();

    let mut report = String::new();

    if !new.is_empty() {
        report.push_str("the CLI does I/O outside cli/src/io:\n");
        for finding in &new {
            report.push_str(&format!("  {}: {}\n", finding.key(), finding.why));
        }
        report.push_str(
            "\nio/ owns every one of these, so the rest of the tree stays testable \
             without a cluster, a daemon or a home directory. Add or reuse an \
             adapter there and call it by name.\n",
        );
    }

    if !stale.is_empty() {
        report.push_str("\nthese baseline entries no longer fire, so the baseline is stale:\n");
        for entry in &stale {
            report.push_str(&format!("  {entry}\n"));
        }
        report.push_str("\nDelete them.\n");
    }

    assert!(report.is_empty(), "{report}");
}

/// The scanner reads the shapes that defeated its predecessors.
///
/// The fixture carries a `#[cfg(test)]` on a `use` rather than a module, two
/// separate test modules with product code between them, a brace inside a raw
/// string and one inside a comment. A scanner that gets any of those wrong
/// reports a clean tree for the wrong reason.
#[test]
fn the_scanner_reads_its_fixture() {
    let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("io-scan");

    let found: Vec<String> = scan_tree(&fixture).iter().map(Finding::key).collect();

    assert_eq!(
        found,
        vec!["tricky.rs:6", "tricky.rs:15", "tricky.rs:30"],
        "the I/O scanner does not read its own fixture correctly"
    );
}

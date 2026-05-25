"""Split nixosOptionsDoc JSON into per-category markdown files for mdBook."""

import json
import os
import sys
from collections import defaultdict

CLUSTER_PREFIX = "lab.clusters.<name>."
COMP_PREFIX = CLUSTER_PREFIX + "components."

COMPONENT_CATEGORIES = {
    "cni": {
        "title": "CNI",
        "components": ["cilium"],
    },
    "gateway": {
        "title": "Gateway and DNS",
        "components": ["gateway", "external-dns"],
    },
    "pki": {
        "title": "PKI",
        "components": ["cert-manager", "trust-manager", "pki-auth"],
    },
    "observability": {
        "title": "Observability",
        "components": ["prometheus", "grafana", "loki", "tempo", "otel-collector"],
    },
    "databases": {
        "title": "Databases",
        "components": ["cnpg", "redis-operator"],
    },
    "filesystems": {
        "title": "Filesystems",
        "components": ["openebs", "seaweedfs"],
    },
    "secrets": {
        "title": "Secrets",
        "components": ["external-secrets", "sops"],
    },
    "identity": {
        "title": "Identity",
        "components": ["kanidm", "kaniop", "oidc"],
    },
    "gitops": {
        "title": "GitOps",
        "components": ["argocd"],
    },
    "source-control": {
        "title": "Source Control",
        "components": ["forgejo"],
    },
    "provisioning": {
        "title": "Provisioning",
        "components": ["cluster-api", "crossplane"],
    },
    "other": {
        "title": "Other Components",
        "components": ["velero", "netbird", "zot", "custom"],
    },
}


def render_option(name, opt):
    """Render a single option as markdown."""
    lines = []
    lines.append(f"## `{name}`\n")

    if opt.get("description"):
        lines.append(opt["description"].strip())
        lines.append("")

    typ = opt.get("type", "")
    if typ:
        lines.append(f"**Type:** `{typ}`\n")

    default = opt.get("default")
    if default is not None:
        default_text = default.get("text", "") if isinstance(default, dict) else str(default)
        if default_text and default_text != "null":
            if len(default_text) > 80 or "\n" in default_text:
                lines.append(f"**Default:**\n```nix\n{default_text}\n```\n")
            else:
                lines.append(f"**Default:** `{default_text}`\n")

    example = opt.get("example")
    if example is not None:
        example_text = example.get("text", "") if isinstance(example, dict) else str(example)
        if example_text:
            if len(example_text) > 80 or "\n" in example_text:
                lines.append(f"**Example:**\n```nix\n{example_text}\n```\n")
            else:
                lines.append(f"**Example:** `{example_text}`\n")

    decls = opt.get("declarations", [])
    if decls:
        links = []
        for d in decls:
            if isinstance(d, dict) and "url" in d:
                links.append(f"[{d['name']}]({d['url']})")
            elif isinstance(d, str):
                links.append(d)
        if links:
            lines.append(f"**Declared in:** {', '.join(links)}\n")

    lines.append("---\n")
    return "\n".join(lines)


def write_page(path, title, description, options, prefix_to_strip=""):
    """Write a markdown page with the given options."""
    with open(path, "w") as f:
        f.write(f"# {title}\n\n")
        if description:
            f.write(f"{description}\n\n")

        if not options:
            f.write("No options in this category.\n")
            return

        sorted_names = sorted(options.keys())
        for name in sorted_names:
            display_name = name
            if prefix_to_strip and name.startswith(prefix_to_strip):
                display_name = name[len(prefix_to_strip):]
            f.write(render_option(display_name, options[name]))


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <options.json> <output-dir>", file=sys.stderr)
        sys.exit(1)

    options_json = sys.argv[1]
    output_dir = sys.argv[2]

    with open(options_json) as f:
        all_options = json.load(f)

    # Remove internal options
    all_options.pop("_module.args", None)

    # Split into categories
    lab_options = {}
    cluster_options = {}
    component_options = defaultdict(dict)
    uncategorized_components = {}

    # Build component-to-category lookup
    comp_to_category = {}
    for cat_id, cat in COMPONENT_CATEGORIES.items():
        for comp in cat["components"]:
            comp_to_category[comp] = cat_id

    for name, opt in all_options.items():
        if name.startswith(COMP_PREFIX):
            rest = name[len(COMP_PREFIX):]
            comp_name = rest.split(".")[0]
            cat_id = comp_to_category.get(comp_name)
            if cat_id:
                component_options[cat_id][name] = opt
            else:
                uncategorized_components[name] = opt
        elif name.startswith(CLUSTER_PREFIX):
            cluster_options[name] = opt
        elif name.startswith("lab."):
            lab_options[name] = opt

    # Write lab options
    os.makedirs(output_dir, exist_ok=True)
    write_page(
        os.path.join(output_dir, "lab.md"),
        "Lab Options",
        "Options for configuring the lab environment, CD strategy, DNS, networking, and operations.",
        lab_options,
        prefix_to_strip="lab.",
    )

    # Write cluster options
    write_page(
        os.path.join(output_dir, "cluster.md"),
        "Cluster Options",
        "Options for configuring individual clusters within a lab, including "
        "Kubernetes settings, provisioners, phases, and authentication.\n\n"
        "All options are under `lab.clusters.<name>.`",
        cluster_options,
        prefix_to_strip=CLUSTER_PREFIX,
    )

    # Write component category pages
    comp_dir = os.path.join(output_dir, "components")
    os.makedirs(comp_dir, exist_ok=True)

    for cat_id, cat in COMPONENT_CATEGORIES.items():
        opts = component_options.get(cat_id, {})
        write_page(
            os.path.join(comp_dir, f"{cat_id}.md"),
            f"{cat['title']} Options",
            f"Options for: {', '.join(cat['components'])}.\n\n"
            f"All options are under `lab.clusters.<name>.components.`",
            opts,
            prefix_to_strip=COMP_PREFIX,
        )

    # Add uncategorized to "other"
    if uncategorized_components:
        other_path = os.path.join(comp_dir, "other.md")
        with open(other_path, "a") as f:
            for name in sorted(uncategorized_components.keys()):
                f.write(render_option(name, uncategorized_components[name]))

    # Print summary
    total = len(lab_options) + len(cluster_options)
    for opts in component_options.values():
        total += len(opts)
    total += len(uncategorized_components)
    print(f"Generated docs for {total} options across {2 + len(COMPONENT_CATEGORIES)} pages")


if __name__ == "__main__":
    main()

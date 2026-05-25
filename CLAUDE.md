# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Development Commands

```bash
# Enter dev shell (provides all tools: talosctl, kubectl, kapp, helm, k3d, etc.)
nix develop

# Build the CLI
cargo build                       # in cli/ directory
cargo watch -x run                # watch mode

# Build via Nix (full wrapped CLI with runtime tools in PATH)
nix build .#cata

# Run the CLI without installing (uses Nix-built binary with all tools)
nix run .#cata -- --flake ./examples/labs#homelab.local lab up

# Format all code (Nix, Rust, YAML)
nix fmt

# Run all checks (CLI build + formatting + lab linting)
nix flake check

# Build rendered manifests for an example lab
nix build '.#labPackages.x86_64-linux."homelab.local"'

# Generate Kubernetes API types from OpenAPI specs and CRDs
nix run .#generate-k8s-types
```

There are no traditional unit tests yet. The CLI has `assert_cmd` in dev-dependencies but no test files. Validation is done via `nix flake check` which runs `cata lab lint` on example labs.

## Architecture

Catallaxy is a declarative Kubernetes platform built on the NixOS module system. It evaluates cluster configurations at Nix build time and renders Kubernetes manifests (Helm charts, typed resources, raw YAML) into deployment-ready packages.

### Two-layer system: Nix modules + Rust CLI

**Nix modules** (`modules/`) define the configuration DSL and manifest rendering. The NixOS module system handles option declaration, type checking, defaults, and lazy cross-references between clusters.

**Rust CLI** (`cli/src/`) orchestrates runtime operations: evaluating Nix expressions, applying manifests to clusters (via kapp/kubectl), managing secrets, PKI, backups, and CAPI bootstrap. It shells out to `nix eval` to get cluster config as JSON.

### Lab → Cluster → Component → Phase → Bundle

- **Lab** (`modules/lab/`) — top-level multi-cluster environment with DNS, ingress, registry, CD strategy, and ops commands.
- **Cluster** (`modules/lab/cluster/`) — single cluster config with components, phases, and provisioner.
- **Component** (`modules/lab/cluster/components/`) — self-contained infrastructure unit (e.g., cert-manager, kanidm, argocd). Declares options AND writes to phase bundles when enabled.
- **Phase** (`modules/lab/cluster/phases/`) — deployment ordering group. Built-in phases: crds(-10) → namespaces(-5) → networking(0) → operators(10) → secrets(20) → infrastructure(30) → gitops(40) → databases(50) → apps(90) → workloads(100).
- **Bundle** — finest-grained unit within a phase. Contains `helmCharts`, `resources` (typed K8s objects), `yamls` (raw manifests), and `createNamespaces`.

### Example lab structure (aspects + clusters + envs)

The example lab uses three layers with no env logic baked into aspects:

```
examples/labs/
  flake.nix                     # Composes lab + env: mkLab [ labs/default.nix envs/local.nix ]
  aspects/                      # Pure feature modules — no env awareness
    networking.nix              # gateway, cert-manager, external-dns, CoreDNS forwarding
    identity.nix                # kanidm users, groups, oauth2 clients
    gitops.nix                  # argocd
    source-control.nix          # forgejo + cnpg
    registry.nix                # zot
    monitoring.nix              # prometheus, loki, tempo, grafana
  clusters/                     # Aspect composition
    core.nix                    # = networking + identity + gitops + source-control + registry + otel
    obs.nix                     # = networking + monitoring + otel gateway
    mgmt.nix                    # CAPI + Crossplane controllers
  labs/
    default.nix                 # THE lab topology + shared ops commands
  envs/                         # Thin environment deltas
    local.nix                   # k3d provisioner, local DNS, ingress
    staging.nix                 # k3d, HA overrides
    prod.nix                    # DO provisioner, mgmt cluster, ACME TLS
  provisioners/
    k3d.nix                     # Local k3d provisioner module
```

### Component pattern (single-file)

```nix
# modules/lab/cluster/components/<category>/<name>.nix
{ config, lib, cataCharts, k8sSpecs, ... }:
let cfg = config.components.<name>;
in {
  options.components.<name> = {
    enable = mkEnableOption "<Name>";
    phase = mkOption { default = "<phase>"; };
    ref = mkOption { type = types.attrs; readOnly = true; };
  };

  config = lib.mkMerge [
    # Computed refs (always available, even when disabled)
    { components.<name>.ref = { ... }; }

    # Phase writer (only when enabled)
    (mkIf cfg.enable {
      phases.${cfg.phase}.bundles.<name>.helmCharts.<name> = { ... };
    })
  ];
}
```

### Cross-cluster references via `lab`

```nix
{ config, lib, lab, ... }:
{
  components.otel-collector.exporters.otlp.endpoint =
    lab.clusters.obs.components.tempo.ref.otlpGrpc;
}
```

### Lab ops — component-aware runtime tooling

Labs can declare operational commands that reference component topology:

```nix
lab.ops.commands.init-user = {
  description = "Reset a kanidm account password";
  package = pkgs.writeShellApplication {
    name = "init-user";
    runtimeInputs = [ pkgs.kubectl ];
    text = ''
      kubectl --context k3d-core exec -n ${kanidmRef.namespace} kanidm-default-0 -- \
        kanidmd recover-account "$1"
    '';
  };
};
```

Run with: `cata lab ops init-user lab-admin`

### Manifest rendering pipeline

1. Components write helm charts, typed resources, and raw YAML into phase bundles
2. `cluster.out.phases` merges all bundles per phase and renders derivations
3. `lab.out.manifests` passes phases through a strategy-specific renderer (kapp, argocd, fleet)
4. `lab.out.package` combines all clusters' manifests + metadata.json + ops tool

### Key lib modules

- `lib/eval-module.nix` — module evaluator with assertion checking
- `lib/eval.nix` — cluster config evaluation and JSON serialization
- `lib/render.nix` — Helm chart, resource, and YAML rendering
- `lib/renderers/` — kapp, argocd, fleet output strategies
- `lib/charts.nix` — centralized Helm chart definitions

## Nix-specific conventions

- Do NOT use `mkIf` inside attribute values passed to `resources` or `yamls` — use `optionalAttrs` or `if/then/else` instead.
- Charts come from `cataCharts.<name>` (built from `lib/charts.nix`). Components accept a `chart` option for overrides.
- `ref` attributes on components are `readOnly` computed values for cross-component wiring. Always set (even when disabled) so other components can reference them safely.
- Lab names support dots (e.g., `homelab.local`). The CLI quotes them in nix eval: `labs.{system}."{name}"`.

## Registries to update when adding a new component

1. `modules/lab/cluster/components/<category>/default.nix` — add import
2. If adding a new category, also add it to `modules/lab/cluster/components/default.nix`

## Registries to update when adding a new chart

1. `lib/charts.nix` — add chart definition with repo, version, chartHash

## Important: do not auto-commit

Do not commit changes automatically. The user handles committing.

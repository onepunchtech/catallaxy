# catallaxy

Declarative Kubernetes platform built on the NixOS module system.

Catallaxy takes its name from F.A. Hayek's term for the spontaneous order that
emerges when independent actors follow their own rules. Applied to
infrastructure: independent component declarations compose into coordinated
multi-cluster environments through Nix's lazy evaluation. There is no imperative
orchestration — just declarations that reference each other, and a build system
that resolves them.

Define your clusters, components, and topology in Nix. Catallaxy evaluates the
configuration, renders Kubernetes manifests (Helm charts, typed resources, raw
YAML), and provides a CLI to provision and manage the result.

**[Documentation](https://defectivenpc.github.io/catallaxy)**

## Why

Kubernetes platform engineering has an accidental complexity problem: YAML sprawl across environments, deployment ordering that lives in tribal knowledge, brittle bash glue that breaks silently, and a management plane that's always click-ops even when everything it manages gets GitOps.

Catallaxy treats your platform like a compilation problem. Declare components in typed Nix modules. Cross-cluster references resolve through lazy evaluation at build time. Phase ordering is a dependency graph, not a runbook. The same declarations compile to kapp, ArgoCD, or Fleet output without changing component code.

If you've felt this pain and recognize that Nix's guarantees — purity, reproducibility, composability — are what infrastructure configuration needs, [read more](https://defectivenpc.github.io/catallaxy/why.html).

## Quick start

```bash
# Enter dev shell (provides kubectl, helm, kapp, k3d, etc.)
nix develop

# Stand up the example homelab (2 clusters: core + obs)
cata --flake ./examples/labs#homelab lab up

# Configure local DNS and trust the lab CA
cata --flake ./examples/labs#homelab lab dns --setup
cata --flake ./examples/labs#homelab lab trust --setup

# Access services by domain
# https://argocd.homelab.test
# https://grafana.homelab.test
# https://kanidm.homelab.test

# Tear down
cata --flake ./examples/labs#homelab lab down
```

## Features

- **Batteries included** — CNI, gateway, PKI, observability, databases,
  identity, GitOps, and more
- **Cross-cluster references** via Nix lazy evaluation — one cluster's Tempo
  endpoint wired into another's OTEL collector
- **Phase-based deployment ordering** — CRDs before operators before
  infrastructure before apps
- **Multiple output strategies** — kapp (direct apply), ArgoCD, Fleet
- **Lab-aware ops tooling** — commands that understand your cluster topology
- **Consumer flake support** — define your lab in your own flake, import
  catallaxy as an input

## Status

**v0.5** — The homelab example boots multi-cluster environments on k3d with
full-stack services and domain-based access. Cloud provisioning and GitOps
integration are next. See the [roadmap](https://defectivenpc.github.io/catallaxy/roadmap.html).

## Build and development

```bash
nix develop                       # dev shell with all tools
cargo build                       # build CLI (in cli/)
nix build .#cata                  # full wrapped CLI with runtime tools
nix fmt                           # format Nix, Rust, YAML
nix flake check                   # build + format + lint checks
```

## Contributing

[contributor guide](https://defectivenpc.github.io/catallaxy/contributing/guide.html).

## License

[MIT](LICENSE)

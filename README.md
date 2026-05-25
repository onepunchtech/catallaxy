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

- **30 components** across 18 categories — CNI, gateway, PKI, observability,
  databases, identity, GitOps, and more
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

See [CONTRIBUTING.md](CONTRIBUTING.md) and the
[contributor guide](https://defectivenpc.github.io/catallaxy/contributing/guide.html).

## License

[MIT](LICENSE)

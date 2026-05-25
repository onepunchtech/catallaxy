# catallaxy

Declarative Kubernetes platform built on the NixOS module system. Independent
component declarations compose into coordinated multi-cluster infrastructure
through Nix's lazy evaluation — no imperative orchestration.

## Status

**Working toward 0.5.** The homelab example boots multi-cluster environments
on k3d with full-stack services (identity, git forge, observability, databases)
and domain-based access via local DNS + HAProxy ingress. Cloud provisioning
(DigitalOcean + Cloudflare) and GitOps integration are next.

## Prerequisites

- Nix with flakes enabled
- Docker running

Everything else (kubectl, kapp, helm, k3d, etc.) is provided by the flake.

## Quick start

```bash
# Enter dev shell with all tools pinned
nix develop

# Stand up the example homelab (2 clusters: internal-services + obs)
cata --flake ./examples/labs#homelab lab up

# Configure local DNS (resolves *.homelab.test → 127.0.0.1)
cata --flake ./examples/labs#homelab lab dns --setup

# Trust the lab CA (no browser cert warnings)
cata --flake ./examples/labs#homelab lab trust --setup

# Access services by domain: https://argocd.homelab.test, https://grafana.homelab.test

# Check status
cata --flake ./examples/labs#homelab lab status

# Tear down
cata --flake ./examples/labs#homelab lab down
```

Or from a consumer flake:

```bash
cata --flake /path/to/my-flake#mylab lab up
```

## Architecture

Two-layer system: **Nix modules** define configuration and render manifests at
build time; a **Rust CLI** orchestrates runtime operations (provisioning,
applying, secrets, PKI).

### Lab → Cluster → Component → Phase → Bundle

- **Lab** — multi-cluster environment with shared DNS, registry, and CD strategy
- **Cluster** — single cluster with components, provisioner, and network config
- **Component** — self-contained unit (e.g., Cilium, cert-manager, ArgoCD) that
  declares options and writes Helm charts / typed resources into phase bundles
- **Phase** — deployment ordering group (crds → networking → operators → infrastructure → gitops → databases → apps)
- **Bundle** — finest-grained unit within a phase (Helm charts, typed K8s resources, raw YAML)

Cross-cluster references work via Nix lazy evaluation:

```nix
# obs cluster can reference internal-services cluster's Tempo endpoint
components.otel-collector.exporters.otlp.endpoint =
  lab.clusters.internal-services.components.tempo.ref.otlpGrpc;
```

### Manifest rendering pipeline

1. Components write Helm charts, typed resources, and raw YAML into phase bundles
2. `cluster.out.phases` merges bundles per phase and renders derivations
3. `lab.out.manifests` passes phases through a strategy-specific renderer (kapp, ArgoCD, or Fleet)
4. `lab.out.package` combines all clusters into a single derivation with `metadata.json`

### 30 components across 18 categories

| Category       | Components                                                |
| -------------- | --------------------------------------------------------- |
| CNI            | Cilium (eBPF, Gateway API, BGP), Flannel (k3s default)    |
| Gateway        | Traefik v3 (Gateway API controller)                       |
| PKI            | cert-manager                                              |
| Observability  | Prometheus, Grafana, Loki, Tempo, OpenTelemetry Collector |
| Databases      | CloudNativePG, Redis Operator                             |
| Filesystems    | OpenEBS, SeaweedFS                                        |
| Registries     | Zot                                                       |
| Secrets        | External Secrets, SOPS                                    |
| Identity       | Kanidm, Kaniop                                            |
| GitOps         | ArgoCD                                                    |
| Source Control | Forgejo                                                   |
| Provisioning   | Cluster API, Crossplane                                   |
| VPN            | Netbird                                                   |
| Backups        | Velero                                                    |
| Infrastructure | External DNS                                              |
| Custom         | User-defined apps (Helm, YAML, typed resources + Gateway) |

### CLI commands

```
cata lab up/down/init/status/list/lint/apply
cata lab publish [--pr] [--dry-run]   # Render + push manifests to git repo
cata lab dns --setup/--teardown       # Configure local DNS resolution
cata lab trust --setup/--teardown     # Manage lab CA trust store
cata cluster up/down/init/status/list
cata apply [--phase] [--component] [--dry-run]
cata pki root-ca/sign/yubikey
cata secrets generate/encrypt/decrypt
cata kubeconfig sync
cata backup create/list/restore/migrate  # Velero backup + cross-cluster migration
cata generate                         # K8s type codegen from OpenAPI + CRDs
```

## Build & development

```bash
nix develop                       # dev shell with all tools
cargo build                       # build CLI (in cli/)
nix build .#cata                  # full wrapped CLI with runtime tools
nix fmt                           # format Nix, Rust, YAML
nix flake check                   # build + format + lint checks
nix eval .#labs.mgmt.config --json | jq .   # evaluate a lab config
nix build .#labPackages.homelab   # build rendered manifests
```

## Project layout

```
flake.nix                           Toolchain, outputs, lab evaluator
modules/
  lab/                              Lab-level options (DNS, registry, ingress, CD)
    cluster/                        Cluster submodule
      components/                   30 components across 18 categories
      phases/                       Phase definitions and ordering
      lib/kubernetes/generated/     Auto-generated K8s types from OpenAPI + CRDs
  lab/provisioners/                 k3d, docker, crossplane
lib/
  eval.nix                          Module evaluation and JSON serialization
  render.nix                        Helm chart, resource, YAML rendering
  renderers/                        kapp, argocd, fleet output strategies
  charts.nix                        Centralized Helm chart definitions
cli/src/
  commands/                         lab, cluster, apply, pki, secrets, backup, generate
  lint/                             Schema, identity, prefix, selector, reference checks
  codegen/                          K8s API type generation from OpenAPI specs
examples/labs/
  homelab.nix                       Multi-cluster lab (internal-services + obs)
  clusters/                         Per-cluster configs
```

## Roadmap to 0.5

**0.5** = declare a multi-cluster environment in a Nix flake and get it
running — on local k3d, on DigitalOcean, or both — with ArgoCD managing
delivery from git, backups ensuring portability, and environments for
dev/staging/prod.

### Phase 1 — Stabilize the foundation (in progress)

Flawless local dev experience with `cata lab up`.

- [x] 29 components with typed options and Helm rendering
- [x] Phase-based deployment ordering with cross-cluster refs
- [x] Lab services: DNS (Knot), Registry, Ingress (HAProxy)
- [x] Gateway API via Traefik v3 (HTTP terminate + TLS passthrough)
- [x] Domain-based access: `https://argocd.homelab.test` on standard ports
- [x] CLI: lab up/down/apply/dns/trust/lint
- [x] Consumer flake support (`--flake path#lab`)
- [ ] Startup reliability (idempotent, correct ordering)
- [ ] All services verified end-to-end

### Phase 2 — Cloud provisioning (DigitalOcean + Cloudflare)

`cata lab up` provisions real cloud infrastructure from a management cluster.

- [ ] Crossplane: DigitalOcean provider (Droplets, LBs, Volumes)
- [ ] Crossplane: Cloudflare provider (DNS, tunnels)
- [ ] Management cluster pattern (explicit, k3d-based, runs CAPI + Crossplane)
- [ ] CAPI: DigitalOcean provider for K8s clusters
- [ ] Cloudflare DNS + Let's Encrypt for production TLS
- [ ] SOPS credentials management for provider secrets

### Phase 3 — CI/CD integration

Rendered manifests flow into git repos, reconciled by ArgoCD/Fleet.

- [ ] ArgoCD app-of-apps bootstrap (`cata lab apply --bootstrap`)
- [ ] `cata lab publish` — render + push to git repo (direct or PR/MR)
- [ ] Push-to-pull transition (day 0 kapp → day 1+ ArgoCD)
- [ ] Git repo structure: one per lab, directory per cluster, ApplicationSet

### Phase 4 — Backup, migration & disaster recovery

Clusters are cattle, not pets.

- [ ] `cata backup create/list/restore` via Velero
- [ ] `cata migrate --from <a> --to <b>` cross-provider migration
- [ ] Management cluster resilience (backup + rebuild from flake)
- [ ] Management cluster pivot (k3d seed → production → delete seed)

### Phase 5 — Environment management

One flake, multiple environments.

- [ ] `lab.environment` enum (development/staging/production)
- [ ] Environment-aware component defaults (replicas, resources, monitoring)
- [ ] `cata promote --from dev --to staging` with git integration
- [ ] Examples: shared base config + per-env overrides

### Phase 6 — Extensibility & hardening (in progress)

- [x] User-defined custom components (`components.custom.apps.<name>`)
- [ ] Property-based testing for render pipeline
- [ ] Cross-platform CI (Linux + macOS)
- [ ] Component authoring guide and architecture docs

## Roadmap to 0.9

- [ ] user extensibility plugin custom modules and transforms
- [ ] On-prem provisioning (Talos, bare-metal)
- [ ] solidified IR passes

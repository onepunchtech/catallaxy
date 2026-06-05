# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.6.0] - 2026-06-05

### Added

- **ACME/Let's Encrypt TLS** — full support for public CA certificates via cert-manager DNS01 challenges with Cloudflare
- **External-DNS with Cloudflare** — auto-create DNS records in Cloudflare zones from Gateway HTTPRoutes
- **Bootstrap & pivot** — self-provisioning cluster detection in planner; k3d bootstrap → cloud migration via Crossplane or CAPI
- **Secrets cache** — SOPS decryption cached in memory across all cluster deployments during `lab up`
- **Projections in metadata** — `metadata.json` includes per-cluster projections and lab-level secrets for package-driven injection
- **Phase ordering assertions** — Nix validates projection phase ≤ component phase in the same namespace
- **`projection-ref` lint check** — validates secretKeyRef names match declared projections with correct phase/namespace
- **`image-pin` lint check** — warns on `:latest` tags, errors on missing digests when `requireDigest` enabled, checks registry allow-lists
- **Image management** — `lab.images.pins` for declarative image pinning with optional digest; `lab.images.allowedRegistries` policy
- **`cata images` command** — `list`, `mirror`, `prefetch` for managing container images with crane
- **Pod Security Standards** — `cluster.security.podSecurity` applies PSA labels to lab namespaces
- **Network Policies** — `cluster.security.networkPolicies` generates default-deny per namespace
- **Audit Logging** — `cluster.security.auditLogging` adds API server audit flags for k3d
- **Extensibility** — `lib.mkComponent` helper, `lib.phases` constants, `lib.mkNetworkPolicy` helper
- **Consumer flake template** — `nix flake init -t github:onepunch/catallaxy#consumer`
- **Custom lint checks** — `lab.lint.checks` for user-defined property checks as shell commands
- **Stuck deployment restart** — auto-restarts deployments in `ProgressDeadlineExceeded` before kapp deploy
- **`cata-dev` alias** — devShell script for running CLI from source via `cargo run`
- **`cata secrets edit` by name** — resolve store name to file path instead of requiring full path

### Changed

- **Lab-aware manifest builds** — `apply` builds from lab package when lab name available, fixing cluster name collisions across labs
- **Projection-only phases** — phases with secret projections but no manifests preserved in rendered output
- **SOPS stderr inherit** — `decrypt_sops_store` inherits stdin/stderr so YubiKey plugins can prompt for PIN
- **Store path fallback** — checks both `secrets/` and `examples/labs/secrets/` for SOPS files
- **Ops tool build** — `lab ops` builds lab package first to ensure ops tool exists in store
- **Ops context templating** — ops scripts use `cluster.ref.kubeContext` instead of hardcoded context names
- **CNPG storage class** — defaults to `null` (cluster default) instead of hardcoded `local-path`
- **Conditional CA bundles** — `lab-ca-bundle` only created with self-signed CA; ACME uses `wellKnownCACertificates: "System"`
- **Kanidm ACME refs** — internal service refs use public URL when ACME active
- **Loki caches disabled** — chunks and results cache disabled by default to reduce memory
- **Renamed `CROSS_PHASE_RESOURCES`** to `RUNTIME_MANAGED_RESOURCES`; projection-aware reference check

### Fixed

- External-dns `domainFilters` for Cloudflare (must be zone name, not subdomain)
- Kanidm Certificate excluding internal SAN when ACME enabled
- Gateway TLS issuerRef using `defaultIssuerRef` instead of hardcoded `lab-ca`
- BackendTLSPolicy using `wellKnownCACertificates: "System"` when no custom CA bundle

### Documentation

- Extending guide — writing custom components, bundle type reference, consumer flake setup
- Security reference — PSA, network policies, audit logging
- Image management reference — pins, policy, lint check
- Lint reference — all built-in checks, custom check authoring, Nix assertions
- Secrets management recipe — SOPS setup, YubiKey workflow, per-environment keys
- Operational runbook — troubleshooting, backup/restore, scaling
- Example labs README — step-by-step cloud setup guide

## [0.5.0] - 2026-05-25

### Added

- Initial release
- Declarative Kubernetes platform management via Nix modules
- Lab → Cluster → Component → Phase → Bundle architecture
- Built-in components: cert-manager, Cilium, Traefik, Prometheus, Grafana, Loki, Tempo, OTEL, ArgoCD, Forgejo, Kanidm, Zot, Velero, CNPG, SeaweedFS
- Crossplane and CAPI provisioners for cloud cluster management
- SOPS integration with 3-layer model (stores, managed secrets, projections)
- GitOps strategy with ArgoCD publish and PR workflow
- Lab ops commands for day-2 operations
- `cata lab lint` with 7 built-in checks
- k3d, Talos, and external provisioner support

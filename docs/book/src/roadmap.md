# Roadmap

Catallaxy development is organized into milestones from v0.5 through v1.0. Each milestone builds on the previous, progressively adding cloud provisioning, GitOps integration, backup workflows, and production hardening.

## v0.5.0 -- Local Platform (current)

The foundation: a fully functional local development platform on k3d.

- Startup reliability improvements and error handling
- End-to-end verification of the full stack (networking, PKI, identity, observability, GitOps)
- Documentation site (this mdBook)
- Lab ops commands for day-2 operations
- TLS trust chain: lab CA distributed via trust-manager, all components use verified TLS
- OIDC integration across ArgoCD, Grafana, and Forgejo via Kanidm

## v0.6.0 -- Cloud Provisioning

Extend beyond local development to cloud infrastructure.

- Crossplane providers for DigitalOcean and Cloudflare
- Cluster API (CAPI) integration for declarative cluster provisioning
- Management cluster pattern: a persistent cluster that provisions and manages workload clusters
- SOPS integration for encrypted secrets in Git
- Multi-provider provisioner abstraction (k3d, CAPI, Talos)

## v0.7.0 -- GitOps Integration

Push-to-pull deployment model for production environments.

- ArgoCD bootstrap: self-managing ArgoCD that syncs from rendered manifests
- `cata lab publish` command: render manifests and push to a Git repository
- Pull request workflow: `--pr` flag creates a PR for review before apply
- Push-to-pull transition: local `cata lab apply` for dev, Git-driven for staging/prod
- Manifest diff previews in PRs

## v0.8.0 -- Backup & Migration

Data protection and cross-provider mobility.

- Velero backup schedules configured per-cluster
- S3-compatible backup storage via SeaweedFS or cloud providers
- Cross-provider cluster migration: backup from one provider, restore to another
- Management cluster pivot: migrate the management cluster itself to new infrastructure
- Backup verification and restore testing

## v0.9.0 -- Environments & Hardening

Environment-aware defaults and operational maturity.

- Environment layers (local, staging, prod) with progressive configuration overrides
- `cata lab promote` workflow: promote changes across environments
- Automated testing framework for lab configurations
- Plugin system for extending the CLI and module system
- Security hardening: network policies, pod security standards, audit logging

## v1.0.0 -- Production Ready

Stable API and production-grade guarantees.

- Stable Nix module API with backward compatibility guarantees
- On-premises support (Talos Linux on bare metal)
- Comprehensive test suite covering module evaluation, rendering, and deployment
- Security audit of the platform and supply chain
- Migration guide from v0.x to v1.0
- Performance benchmarking and optimization for large multi-cluster labs

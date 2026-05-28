# Roadmap

## 1.0 — Production Ready

### Local Platform

- [x] Startup reliability improvements and error handling
- [x] End-to-end verification of the full stack (networking, PKI, identity, observability, GitOps)
- [x] Documentation site (mdBook)
- [x] Lab ops commands for day-2 operations
- [x] TLS trust chain: lab CA distributed via trust-manager, all components use verified TLS
- [x] OIDC integration across ArgoCD, Grafana, and Forgejo via Kanidm

### Cloud Provisioning

- [x] SOPS integration for encrypted secrets in Git
- [x] Crossplane providers for DigitalOcean and Cloudflare
- [x] Cluster API (CAPI) integration for declarative cluster provisioning
- [x] Management cluster pattern: a persistent cluster that provisions and manages workload clusters
- [x] Multi-provider provisioner abstraction (k3d, CAPI, Talos)

### GitOps

- [x] ArgoCD bootstrap: self-managing ArgoCD that syncs from rendered manifests
- [x] `cata lab publish` command: render manifests and push to a Git repository
- [x] Pull request workflow: `--pr` flag creates a PR for review before apply
- [x] Push-to-pull transition: direct apply blocked for GitOps labs unless `--force`

### Backup & Migration

- [x] Velero backup schedules configured per-cluster
- [x] S3-compatible backup storage via SeaweedFS or cloud providers
- [x] Cross-provider cluster migration: backup from one provider, restore to another
- [x] Management cluster pivot: migrate the management cluster itself to new infrastructure
- [x] Backup verification and restore testing

### Environments

- [x] Environment layers (local, staging, prod) with progressive configuration overrides

### Hardening & Stability

- [ ] Stable Nix module API with backward compatibility guarantees
- [ ] Security hardening: network policies, pod security standards, audit logging
- [ ] Comprehensive test suite covering module evaluation, rendering, and deployment
- [ ] Security audit of the platform and supply chain
- [x] Pre-flight validation in `cata lab lint` (environment, config, and manifest checks)
- [ ] CHANGELOG and versioned releases

### Extensibility

- [ ] Custom components, charts, and transformation passes without forking
- [ ] Consumer flake extensibility: teams define their own modules that compose with built-in components
- [ ] Documentation for writing and distributing custom component modules

### Documentation

- [ ] Secrets management recipe (SOPS setup, team workflows, per-environment keys)
- [ ] Operational runbooks (backup/restore, disaster recovery, troubleshooting)
- [ ] Consumer flake guide for custom charts and components

## Future

Ideas worth capturing but not blocking 1.0. These are distractions until the above is done.

- [ ] Performance benchmarking and optimization for large multi-cluster labs
- [ ] Migration guide from v0.x to v1.0
- [ ] Automated testing framework for lab configurations
- [ ] On-premises support (Talos Linux on bare metal)
- [ ] compute sboms
- [ ] image package set for reproducible image refs

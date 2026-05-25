# Introduction

Catallaxy is a declarative Kubernetes platform built on the NixOS module system. It lets you define multi-cluster environments entirely in Nix, producing rendered manifests and runtime tooling as build outputs — no imperative orchestration required.

## The name

The term "catallaxy" comes from F.A. Hayek's description of a spontaneous order: a complex, coordinated system that emerges not from central planning, but from independent actors following their own rules. In economics, this is the market. In catallaxy, it is your infrastructure.

Each component — cert-manager, ArgoCD, Prometheus, Kanidm, and roughly 30 others across 18 categories — is a self-contained declaration. It defines its own options, its own defaults, and writes its own manifests into the appropriate deployment phase. No component knows the full picture. Yet through Nix's lazy evaluation and the module system's merge semantics, these independent declarations compose into a coherent, cross-referenced, multi-cluster platform.

There is no imperative glue. No ordering logic scattered across scripts. Components declare what they need, reference what they depend on, and the system resolves it all at build time.

## What it does

You write Nix modules that describe your lab — its clusters, their components, networking, identity, observability, and anything else you need. Catallaxy evaluates those modules and produces:

- **Rendered Kubernetes manifests** — Helm charts templated, typed resources serialized, raw YAML collected, all organized by deployment phase.
- **A deployment package** — manifests bundled with metadata, ready for application via kapp, ArgoCD, or Fleet.
- **Runtime tooling** — a CLI (`cata`) that handles cluster lifecycle, secret management, PKI, DNS, and operational commands defined in your lab configuration.

The system has two layers:

- **Nix modules** define the configuration DSL, perform type checking, resolve cross-references between clusters, and render all manifests at build time.
- **A Rust CLI** (`cata`) orchestrates runtime operations: evaluating Nix expressions, applying manifests to clusters, managing secrets, and running ops commands.

## Status

Catallaxy is at **v0.5** — functional and in active use, but the API is not yet stable. Expect breaking changes between minor versions. Feedback and contributions are welcome.

## Where to go from here

- [Getting Started](./getting-started/prerequisites.md) — install prerequisites and stand up your first lab.
- The architecture and component reference sections cover the internals in detail.

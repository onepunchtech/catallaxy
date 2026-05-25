# Module Options

Auto-generated reference for all catallaxy module options. Options are split
across pages by category to keep each page fast to load.

## Lab options

Top-level lab configuration: name, environment, CD strategy, DNS, networking,
ingress, registry, and ops commands.

- [Lab Options](./options/lab.md)

## Cluster options

Per-cluster configuration nested under `lab.clusters.<name>`: Kubernetes
settings, provisioners, phases, authentication, and storage.

- [Cluster Options](./options/cluster.md)

## Component options

Each component declares options under `lab.clusters.<name>.components.<name>`.
Pages are grouped by category:

| Category | Components |
|----------|-----------|
| [CNI](./options/components/cni.md) | Cilium |
| [Gateway and DNS](./options/components/gateway.md) | Gateway, External DNS |
| [PKI](./options/components/pki.md) | cert-manager, trust-manager |
| [Observability](./options/components/observability.md) | Prometheus, Grafana, Loki, Tempo, OTEL Collector |
| [Databases](./options/components/databases.md) | CloudNativePG, Redis Operator |
| [Filesystems](./options/components/filesystems.md) | OpenEBS, SeaweedFS |
| [Secrets](./options/components/secrets.md) | External Secrets, SOPS |
| [Identity](./options/components/identity.md) | Kanidm, Kaniop, OIDC |
| [GitOps](./options/components/gitops.md) | ArgoCD |
| [Source Control](./options/components/source-control.md) | Forgejo |
| [Provisioning](./options/components/provisioning.md) | Cluster API, Crossplane |
| [Other](./options/components/other.md) | Velero, Netbird, Zot, Custom |

## How options are structured

Every component follows the same pattern:

```nix
options.components.<name> = {
  enable = mkEnableOption "<Name>";
  phase = mkOption { default = "<phase>"; };
  namespace = mkOption { default = "<namespace>"; };
  chart = mkOption { ... };
  ref = mkOption { readOnly = true; };
};
```

The `ref` attribute provides computed values for cross-component wiring. It is
always set, even when the component is disabled, so other components can
reference it safely.

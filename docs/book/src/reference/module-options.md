# Module Options

Auto-generated module option documentation is planned but not yet available.

## Finding options in source

All module options are defined in Nix files using the standard NixOS module system (`mkOption`, `mkEnableOption`, `types.*`).

### Lab options

Top-level lab configuration: DNS, ingress, registry, CD strategy, ops commands.

Source: `modules/lab/`

### Cluster options

Per-cluster configuration: Kubernetes version, provisioner, components, phases.

Source: `modules/lab/cluster/`

### Component options

Each component is a single-file module with its own options under `components.<name>`.

Source: `modules/lab/cluster/components/`

Components are organized by category:

| Category | Path |
|----------|------|
| Backups | `components/backups/` |
| CNI | `components/cni/` |
| Databases | `components/databases/` |
| Filesystems | `components/filesystems/` |
| GitOps | `components/gitops/` |
| Identity | `components/idm/` |
| Observability | `components/observability/` |
| PKI | `components/pki/` |
| Provisioning | `components/provisioning/` |
| Registries | `components/registries/` |
| Secrets | `components/secrets/` |
| Source Control | `components/source-control/` |
| VPN | `components/vpn/` |
| Custom | `components/custom.nix` |
| Gateway | `components/gateway.nix` |
| External DNS | `components/external-dns.nix` |
| Redis | `components/redis-operator.nix` |

### Phase options

Deployment phase configuration: ordering, dependencies, timeouts, pruning.

Source: `modules/lab/cluster/phases/default.nix`

See the [Phases reference](./phases.md) for details on built-in phases.

## Reading option definitions

Each component follows a consistent pattern. Look for the `options` attribute set to see what can be configured:

```nix
options.components.<name> = {
  enable = mkEnableOption "<Name>";
  phase = mkOption { default = "<phase>"; };
  namespace = mkOption { default = "<namespace>"; };
  chart = mkOption { ... };      # Helm chart override
  ref = mkOption { readOnly = true; };  # Cross-component references
  # ... component-specific options
};
```

The `ref` attribute is always `readOnly` and provides computed values that other components can reference. It is set even when the component is disabled.

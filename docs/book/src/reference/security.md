# Security

Catallaxy provides three cluster-level security features that derive policies from existing component configuration. Enable with simple toggles — the system generates the right policies.

## Pod Security Standards

Kubernetes [Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/) labels control what pods can do in each namespace.

```nix
cluster.security.podSecurity = {
  enable = true;
  default = "restricted";  # "restricted" | "baseline" | "privileged"
};
```

When enabled, all lab-managed namespaces get PSA labels:

```yaml
metadata:
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
```

### Per-Namespace Overrides

Components that need elevated privileges (Cilium, kaniop, etc.) can override per namespace:

```nix
cluster.security.podSecurity.namespaceOverrides = {
  kube-system = "privileged";
  kanidm = "baseline";
};
```

### PSA Levels

| Level | Description |
|-------|-------------|
| `restricted` | No host networking, no root, no privilege escalation. Most secure. |
| `baseline` | Prevents known privilege escalations. Allows most workloads. |
| `privileged` | Unrestricted. For system components (CNI, node agents). |

## Network Policies

Default-deny network policies restrict pod-to-pod traffic. When enabled, each lab namespace gets a policy that blocks all traffic except:

- **DNS** (UDP/TCP 53) — pods can resolve names
- **Same-namespace** — pods in the same namespace can talk to each other

```nix
cluster.security.networkPolicies.enable = true;
```

### Cross-Namespace Access

Components that need cross-namespace traffic add their own allow rules in their phase bundles. Use the `mkNetworkPolicy` helper:

```nix
{ config, lib, ... }:
let
  catallaxyLib = config._module.args.catallaxyLib or {};
in
lib.mkIf config.cluster.security.networkPolicies.enable {
  phases.apps.bundles.my-app.resources.my-app-netpol =
    catallaxyLib.mkNetworkPolicy {
      name = "allow-gateway-ingress";
      namespace = "my-app";
      podSelector.matchLabels."app" = "my-app";
      policyTypes = ["Ingress"];
      ingress = [{
        from = [{ namespaceSelector.matchLabels."kubernetes.io/metadata.name" = "kube-system"; }];
        ports = [{ port = 8080; }];
      }];
    };
}
```

### Built-in Components

Built-in components will progressively add their own network policies when this feature is enabled. The default-deny baseline ensures nothing is open by accident.

## Audit Logging

Kubernetes API server audit logging records who did what.

```nix
cluster.security.auditLogging.enable = true;
```

### Provisioner Behavior

| Provisioner | Behavior |
|-------------|----------|
| **k3d** | Adds `--audit-policy-file` and `--audit-log-path` API server args. Audit policy mounted from host. |
| **DOKS** | Managed by DigitalOcean. This option is a no-op. |
| **Talos** | Machine config for audit policy (future). |

### k3d Audit Policy

When enabled on k3d, an audit policy file is mounted at `/etc/kubernetes/audit/policy.yaml`. The default policy logs:
- All authentication events
- All resource creation/deletion
- Metadata for read operations

Audit logs are written to `/var/log/kubernetes/audit.log` inside the k3d node container.

## Enabling All Security Features

```nix
# In your cluster config:
cluster.security = {
  podSecurity.enable = true;
  networkPolicies.enable = true;
  auditLogging.enable = true;
};
```

This gives you defense-in-depth: pod restrictions, network segmentation, and an audit trail — all derived from your existing lab configuration.

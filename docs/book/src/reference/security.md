# Cluster Security

Opt-in controls at `cluster.security.*`, all defaulting to off so a first
`lab up` is not a debugging session. Turn them on per cluster:
[`podSecurity`](./options/cluster.md#cluster-security-podsecurity-enable),
[`networkPolicies`](./options/cluster.md#cluster-security-networkpolicies-enable),
[`auditLogging`](./options/cluster.md#cluster-security-auditlogging-enable).

## Pod Security Admission

```nix
cluster.security.podSecurity = {
  enable = true;
  default = "restricted";               # restricted | baseline | privileged
  namespaceOverrides = {
    "kube-system" = "privileged";
    "cilium" = "privileged";
  };
};
```

Labels every lab-managed namespace for
[Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/).
`restricted` is the strict profile: no privilege escalation, non-root,
seccomp, dropped capabilities.

`namespaceOverrides` exists because CNIs and storage drivers genuinely need
host access. Start with `restricted` as the default and add overrides as
things fail: the failures are explicit admission errors, not silent
misbehaviour.

Namespaces the lab does not manage are untouched.

## Network policies

```nix
cluster.security.networkPolicies.enable = true;
```

Generates a default-deny `NetworkPolicy` for every lab-managed namespace,
allowing only:

- **DNS egress**. UDP/TCP 53, so resolution keeps working
- **same-namespace traffic**, pods in a namespace can reach each other.

Everything else is denied, and each floe adds its own allow rules for the
traffic it actually needs. This requires a CNI that enforces NetworkPolicy.
Cilium does. k3d's default Flannel does not, so on a local k3d lab the
policies are applied and inert.

`catallaxy.lib.mkNetworkPolicy` builds allow rules without hand-writing the
shape.

## Audit logging

```nix
cluster.security.auditLogging.enable = true;
```

Enables API server audit logging. Implementation is provisioner-specific: a
managed control plane may expose it as a flag, or not at all. Check your
provisioner before relying on it.

## What this page does not cover

Security controls that live elsewhere:

| Concern                                  | Where                                 |
| ---------------------------------------- | ------------------------------------- |
| TLS and CA trust                         | [TLS and the Lab CA](../using/tls.md) |
| Encrypted secrets                        | [Secrets](../using/secrets.md)        |
| Image provenance and registry allowlists | [Images and Registries](./images.md)  |
| Client certificates on a YubiKey         | `cata pki`, [CLI](./cli.md#cata-pki)  |

Single sign-on and what is reachable from outside the cluster are floe
options: see `kanidm` and `gateway` on the [option pages](./options.md).

## A note on defaults

They all default to `false`. That is a deliberate trade: a framework whose
first run fails admission teaches people to disable the security feature,
not to configure it. Turn them on once the lab works, one at a time, and
read the failures.

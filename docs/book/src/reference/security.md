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

Generates a default-deny policy for every lab-managed namespace, allowing
only:

- **DNS egress**. UDP/TCP 53, so resolution keeps working
- **same-namespace traffic**, pods in a namespace can reach each other
- **API server egress**. Nearly every floe runs a controller that needs it,
  and a pod that cannot reach the API server is the common broken case.

Everything else is denied, and each floe declares the traffic it needs on
top. This requires a CNI that enforces policy. Cilium does. k3d's default
Flannel does not, so on a local k3d lab the policies are applied and inert.

Namespaces the lab does not create are left alone, even when a floe runs in
one. A namespace with no policy is unrestricted, and adding one starts
denying everything else in it: for `kube-system`, where the gateway runs,
that would be the cluster's own components.

A floe's own rules go into the namespace its pods are in, which is
`floes.<name>.namespace`, and nowhere else. Creating a namespace for
somebody else is not a reason to hand that namespace your permissions: cnpg
creates one per Postgres cluster, and a policy selects every pod in its
namespace, so writing cnpg's rules wherever it creates would give the
application living there the API-server ingress that only the cnpg webhook
wants. Those namespaces still get the default-deny, like every other
namespace the lab manages.

### What a floe declares

The half that answers names its ports; the half that connects names the
label.

```nix
floes.openbao.network = {
  declared = true;
  serves.api.port = 8200;
};

floes.external-secrets.network = {
  declared = true;
  reaches = [ "openbao/api" ];
  serves.webhook = {
    port = 443;
    fromApiServer = true;      # an admission webhook
  };
  egress.internet.ports = [ 443 ];
};
```

A port number therefore exists in exactly one place, next to the thing that
answers on it. A client writes no number, so it cannot write a wrong one,
and `openbao/api` naming a floe or label that does not exist fails
evaluation rather than rendering a rule that does nothing.

Ingress is derived from the union of everyone's `reaches`, so a flow is
declared once and cannot be half-declared. `serves` carries who else may
reach a port: `fromExternal` for a LoadBalancer, `fromApiServer` for a
webhook.

`declared` is the floe saying its traffic has been worked out. A floe
needing nothing beyond the defaults still sets it, so that it reads as
reviewed rather than as overlooked, and a check fails on any floe that never
does.

The gateway is derived rather than declared: every exposed floe already
renders an `HTTPRoute` naming its backend and port, so that is read back
instead of restating it.

`floes.<name>.network` is an ordinary option, so a lab adds rules a floe did
not anticipate by setting it directly.

### What a namespace gets

```nix
cluster.security.networkPolicies = {
  enable = true;

  default.egress.internet.ports = [ ];

  namespaceOverrides.harbor = {
    egress.internet.ports = [ 443 ];
  };
};
```

An override is used instead of `default` rather than merged into it, so what
a namespace ends up with reads in one place. `dns`, `apiServer` and
`sameNamespace` still default to true there: replacing the rest is a
reasonable thing to want, silently dropping name resolution because a line
was not restated is not.

### Two dialects

Where the cilium floe is enabled, policies render as `CiliumNetworkPolicy`
and name the API server outright with `toEntities: [kube-apiserver]`.
Otherwise they render as plain `NetworkPolicy`, which cannot: the API server
is a ClusterIP that resolves to a host-network node address, so the only way
to permit it is an address range covering the control plane.
[`apiServerCidrs`](./options/cluster.md#cluster-security-networkpolicies-apiservercidrs)
is that range, defaulting to the docker bridge the lab's nodes sit on.

This is coarser than it looks, and it is the reason to prefer Cilium where
the choice is open: the range is permitted to every pod in the lab on the
API ports.

The two dialects also have to be told to deny the same things. A plain
`NetworkPolicy` sets both `policyTypes` unconditionally, so a policy with
only egress rules still denies all ingress. Cilium defaults enforcement to
false for any direction a policy carries no rules for, so the same input
would leave ingress open, and a default-deny in a namespace that asked for
nothing would enforce nothing at all. Every `CiliumNetworkPolicy` therefore
renders `enableDefaultDeny` for both directions.

Both dialects refuse a rule whose peer list comes out empty. That is not "no
peer": Kubernetes reads an absent or empty `to` as matching every
destination, so a rule that meant to name two namespaces and named none
would quietly become the widest rule in the policy. "Any destination on
these ports" is spelled by omitting the peer list, which is what the
`anywhere` peer renders to, rather than by emptying it.

### Checking it without a cluster

Whether a policy set is right normally shows up only on a running cluster: a
wrong port builds fine and fails as a timeout somewhere.

It does not have to. The rendered manifests already say what talks to what,
so `cata lab lint` compares them against the policies:

```
error: otel-collector is configured to reach prometheus:9090,
       but no policy permits it
error: kanidm/https serves port 8443, but no Service in kanidm
       exposes it (it exposes 443)
warning: argocd may reach openbao:8200, but nothing references it
```

Every `Service` in the tree gives the real ports; every service reference in
a ConfigMap, an env var or a chart value gives what the software was
configured to do. A candidate reference counts only when the namespace is
one the lab manages and the service exists in it, which is what separates
`loki.loki.svc.cluster.local:3100` from an ordinary domain name.

The first two findings are errors. The third is a warning, because a
legitimate flow need not be written as a URL anywhere.

Flow findings need a lab that renders policies, so a lab with
`networkPolicies` off gets only the `serves`-against-Service half. That one
runs everywhere, since a wrong port number is wrong either way.

### What it does not cover

Prometheus scrapes through `ServiceMonitor` resources that charts create at
install time. Those name a Service by label selector rather than by address,
so neither the policies nor the analyser can see them: a lab enabling
policies alongside prometheus adds those rules itself.

The analyser reads addresses. Software that finds its peers some other way,
through service discovery or an operator writing config at runtime, is
invisible to it, and for those the only check is still a running cluster.

`catallaxy.lib.mkNetworkPolicy` still builds a policy by hand for anything
outside this model.

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
| Client certificates on a YubiKey         | [Client Certificates](./pki.md)       |

Single sign-on and what is reachable from outside the cluster are floe
options: see `kanidm` and `gateway` on the [option pages](./options.md).

## A note on defaults

They all default to `false`. That is a deliberate trade: a framework whose
first run fails admission teaches people to disable the security feature,
not to configure it. Turn them on once the lab works, one at a time, and
read the failures.

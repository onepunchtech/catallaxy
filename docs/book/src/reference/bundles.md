# Writing a Bundle

A bundle is a group of Kubernetes resources installed as a unit, and the
node type of the install DAG. You write one at `bundles.<name>`, and the key
is its identity everywhere else: `bundle:<name>` anchors,
`cluster.provisioning.rootBundles`, and the per-bundle directory in the
rendered manifest tree.

Every field, with its type and default, is in
[Bundle Options](./options/bundles.md). This page is the judgement the
schema cannot carry.

## `after` versus `requires`

[`after`](./options/bundles.md#after) is pure sequencing: B lands in a later
wave than A. [`requires`](./options/bundles.md#requires) additionally blocks
on A's ready probe.

Reach for `requires` whenever the dependency is on state A _creates_, a CRD
becoming Established or a Certificate being issued, rather than merely on
A's manifests existing. Applying a CRD and the CRD being usable are two
different moments, and most ordering bugs live in the gap.

Take a peer's token from its capability rather than spelling it:
`refs.needs config.floes.gateway.exports.routing "publicReady"` in
`requires`. The grammar for both fields is in
[Anchors and Tokens](./anchors.md).

## Choosing a ready probe

[`readyProbe`](./options/bundles.md#readyprobe) is `null` for purely
declarative bundles: a Secret, a ConfigMap, a Namespace is ready the moment
it applies. Give one to a bundle that _mints state_, so a downstream
`requires` blocks until the state is real rather than until the manifest
landed.

| `kind`         | Waits for                        | Runs           |
| -------------- | -------------------------------- | -------------- |
| `condition`    | a status condition on a resource | host-side      |
| `jsonpath`     | a JSONPath expression to match   | host-side      |
| `exists`       | a resource to exist at all       | host-side      |
| `script`       | an arbitrary script to exit 0    | host-side      |
| `kubectl-wait` | free-form `kubectl wait` args    | host-side      |
| `http`         | an HTTP endpoint to answer       | in-cluster Pod |
| `tcp`          | a TCP port to accept             | in-cluster Pod |
| `dns`          | a name to resolve                | in-cluster Pod |

Host-side probes run against the operator's kubeconfig. The three network
shapes address endpoints the host generally cannot reach, so the renderer
turns them into a one-shot Pod. **That Pod carries no ServiceAccount and so
cannot mount the lab CA bundle.** If a probe needs the lab CA, put a
`mkWaitInitContainer` inside the bundle's own workload, where the volume
already exists, and give the bundle a kubectl-native probe instead.

The `ready-probe` [lint rule](./lint.md) catches a probe naming something
the bundle neither renders nor can mint after apply, which would otherwise
block until its timeout and then fail the deploy, minutes later and far from
the cause.

## Helm charts

Resources carrying a `helm.sh/hook` annotation are stripped during render.
See [How It Works](../understanding/how-it-works.md) for why, and what to do
instead.

## Example

```nix
bundles.redis-operator = {
  includeInBootstrap = false;
  helmCharts.redis-operator = {
    chart = cfg.chart;
    namespace = cfg.namespace;
  };
  createNamespaces = [ cfg.namespace ];

  provides = [ "redis-operator/ready" ];
  readyProbe = {
    kind = "condition";
    resource = "deployment/redis-operator";
    namespace = cfg.namespace;
    condition = "Available";
    timeout = "3m";
  };
};
```

Nothing here states _when_ to install it. Downstream bundles declare
`requires = [ "redis-operator/ready" ]`, and the wave partition follows.

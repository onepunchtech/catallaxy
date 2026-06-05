# Extending Catallaxy

Catallaxy is designed to be extended without forking. Teams can add custom components, Helm charts, provisioners, and operational commands by writing NixOS modules that compose with the built-in components.

## Architecture

The extensibility model is simple: **the Nix module system is the extension mechanism.**

Components write to a shared namespace (`phases.${name}.bundles.${name}`), and the rendering pipeline consumes those bundles to produce Kubernetes manifests. The bundle type is the stable contract:

```nix
bundleType = {
  resources = attrsOf kubernetesResourceType;  # Typed K8s resources
  helmCharts = attrsOf helmChartType;          # Helm charts with values
  yamls = listOf (either str path);            # Raw YAML strings or files
  createNamespaces = listOf str;               # Namespaces to create
};
```

Everything upstream of bundles (component options, user config) is the **frontend**. Everything downstream (rendering, strategy layout) is the **backend**. Your custom modules operate in the frontend — declaring options and producing bundles.

## Getting Started

```bash
nix flake init -t github:onepunch/catallaxy#consumer
```

This creates a consumer flake with a working custom component example.

## Extension Points

| What | How | Example |
|------|-----|---------|
| Custom component | Module writing to `phases.bundles` | [Writing Components](./components.md) |
| Custom Helm chart | `helmCharts.${name}` in a bundle | [Helm Charts](./components.md#helm-charts) |
| Custom phase | `phases.${name}.order = N` | [Phase Ordering](../reference/phases.md) |
| Secret projections | `secrets.projections.${name}` | [Secrets](../reference/secrets.md) |
| Ops commands | `ops.${name}` | [Ops Commands](../reference/ops.md) |
| Lifecycle hooks | `lifecycle.teardown` | [Lifecycle](../reference/lifecycle.md) |

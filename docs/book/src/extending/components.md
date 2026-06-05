# Writing Custom Components

A component is a NixOS module that declares high-level options and writes Kubernetes resources into phase bundles. This is the same pattern used by all built-in components (ArgoCD, Prometheus, Kanidm, etc.).

## The Pattern

Every component follows three parts:

1. **Options** — what the user configures
2. **Refs** — computed values other components can read
3. **Phase writer** — produces bundles when enabled

```nix
{ config, lib, ... }:
let
  cfg = config.components.my-app;
in
{
  # 1. Options
  options.components.my-app = {
    enable = lib.mkEnableOption "my-app";
    phase = lib.mkOption { type = lib.types.str; default = "apps"; };
    namespace = lib.mkOption { type = lib.types.str; default = "my-app"; };
    domain = lib.mkOption { type = lib.types.str; };
    ref = lib.mkOption { type = lib.types.attrs; readOnly = true; };
  };

  config = lib.mkMerge [
    # 2. Refs (always computed, even when disabled)
    {
      components.my-app.ref = {
        namespace = cfg.namespace;
        url = "http://my-app.${cfg.namespace}.svc.cluster.local";
      };
    }

    # 3. Phase writer (only when enabled)
    (lib.mkIf cfg.enable {
      phases.${cfg.phase}.bundles.my-app = {
        resources = { /* K8s resources */ };
        helmCharts = { /* Helm charts */ };
        createNamespaces = [ cfg.namespace ];
      };
    })
  ];
}
```

## Bundle Type

The bundle is the contract between your component and the rendering pipeline:

### `resources`

Typed Kubernetes resource definitions as Nix attribute sets:

```nix
resources.my-deployment = {
  apiVersion = "apps/v1";
  kind = "Deployment";
  metadata = { name = "my-app"; namespace = cfg.namespace; };
  spec = { /* ... */ };
};
```

### `helmCharts`

Helm charts with values:

```nix
helmCharts.my-app = {
  chart = myChartDerivation;  # A Nix derivation containing the chart
  releaseName = "my-app";
  namespace = cfg.namespace;
  createNamespace = true;
  values = {
    replicaCount = 3;
    image.tag = cfg.version;
  };
};
```

### `yamls`

Raw YAML strings or file paths (for resources that don't fit the typed model):

```nix
yamls = [
  ./manifests/custom-crd.yaml
  (builtins.toJSON { apiVersion = "v1"; kind = "ConfigMap"; /* ... */ })
];
```

### `createNamespaces`

Namespaces that should be created before this bundle deploys:

```nix
createNamespaces = [ cfg.namespace ];
```

## Phase Ordering

Components target a phase by name. Built-in phases and their order:

| Phase | Order | Use for |
|-------|-------|---------|
| crds | -10 | Custom Resource Definitions |
| namespaces | -5 | Namespace creation (automatic) |
| networking | 0 | CNI, Gateway, DNS |
| operators | 10 | Controllers and operators |
| secrets | 20 | Secret management |
| infrastructure | 30 | Core services (identity, monitoring) |
| gitops | 40 | GitOps controllers |
| databases | 50 | Database instances |
| apps | 90 | Applications |
| workloads | 100 | User workloads |

Custom phases can be defined with any order value.

## Using `mkComponent`

For simple components, use the `mkComponent` helper:

```nix
# In your flake:
catallaxy.lib.mkComponent {
  name = "my-app";
  phase = "apps";
  options = {
    domain = lib.mkOption { type = lib.types.str; };
    replicas = lib.mkOption { type = lib.types.int; default = 1; };
  };
  module = cfg: {
    phases.apps.bundles.my-app = {
      helmCharts.my-app = {
        chart = myChart;
        releaseName = "my-app";
        namespace = cfg.namespace;
        values = { host = cfg.domain; replicas = cfg.replicas; };
      };
      createNamespaces = [ cfg.namespace ];
    };
  };
}
```

## Cross-Component References

Components expose computed values via `ref` for other components to consume:

```nix
# In your component:
components.my-app.ref = {
  url = "http://my-app.${cfg.namespace}.svc.cluster.local:8080";
  namespace = cfg.namespace;
};

# In another component:
config.components.my-app.ref.url  # → "http://my-app.my-app.svc.cluster.local:8080"
```

## Consumer Flake

Pass your component modules to `mkLab`:

```nix
{
  inputs.catallaxy.url = "github:onepunch/catallaxy";

  outputs = { catallaxy, ... }:
    catallaxy.lib.eachDefaultSystem (system: {
      labs."my-platform" = (catallaxy.${system}.mkLab {
        modules = [ ./lab.nix ./components/my-app.nix ];
      }).config.lab.out.cliConfig;
    });
}
```

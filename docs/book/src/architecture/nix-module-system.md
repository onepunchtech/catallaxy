# The NixOS Module System

Catallaxy uses the NixOS module system as its configuration engine. This is the same system that powers NixOS (the Linux distribution), but applied to Kubernetes cluster configuration instead of operating system configuration. This page explains why it was chosen and how Catallaxy uses its key features.

## Why NixOS Modules

The NixOS module system provides several properties that are difficult to achieve with other configuration tools:

### Type Checking at Evaluation Time

Every option has a declared type. When a user sets a value that does not match the expected type, the error is caught during `nix eval` -- before any manifest is rendered or any cluster is touched.

```nix
# This declaration...
options.components.cert-manager.namespace = lib.mkOption {
  type = lib.types.str;
  default = "cert-manager";
};

# ...means this is caught immediately:
components.cert-manager.namespace = 42;
# error: A definition for option `components.cert-manager.namespace`
# is not of type `string`.
```

The type system extends to complex structures. Kubernetes resources are typed using NixOS module types generated from OpenAPI specs and CRDs, so structural errors in resource definitions are caught at evaluation time rather than at apply time.

### Lazy Evaluation and Cross-References

Nix is a lazy language: values are only computed when they are needed. This enables circular module references that would cause infinite loops in eager languages.

```nix
# Module A sets a value that references module B
config.components.otel-collector.endpoint =
  config.components.tempo.ref.otlpGrpc;

# Module B sets a value that references module A
config.components.tempo.forwarders =
  [ config.components.otel-collector.ref.receiverEndpoint ];
```

As long as the dependency graph is acyclic at the value level (no value depends on itself), Nix resolves everything correctly. This is what makes the `ref` pattern and cross-cluster references possible.

### Merge Semantics

When multiple modules set the same option, the module system merges them according to the option's type:

- **Attribute sets** are recursively merged
- **Lists** are concatenated
- **Scalars** cause an error (unless one uses `mkDefault`, `mkForce`, or priority)

This is how components from different files accumulate bundles into the same phase without coordination:

```nix
# cert-manager writes to phases.operators.bundles
phases.operators.bundles.cert-manager.helmCharts.cert-manager = { ... };

# prometheus also writes to phases.operators.bundles
phases.operators.bundles.prometheus.helmCharts.prometheus = { ... };
```

The module system merges these two definitions into a single `phases.operators.bundles` attrset.

### Defaults and Overrides

Options can have defaults (`mkDefault`), and users can override them at multiple priority levels:

```nix
# Component sets a default phase
phase = lib.mkDefault "operators";

# User overrides it in their cluster config
components.cert-manager.phase = "infrastructure";
```

This enables the environment layering pattern: aspects define feature defaults, and environment deltas override provisioner settings, DNS configuration, and TLS mode.

### Assertions

Modules can declare assertions that are checked after evaluation:

```nix
config.assertions = [
  {
    assertion = config.components.cert-manager.acme.enable
                -> config.components.cert-manager.acme.email != "";
    message = "ACME email must be set when ACME is enabled";
  }
];
```

Failed assertions are collected and reported as a single error, giving the user a complete list of problems to fix.

## The `out` Pattern

Computed output values follow a convention of being placed under an `out` attribute. These are `readOnly` options that the module system computes from other configuration values.

### Cluster-Level `out`

`cluster.out` (`modules/lab/cluster/out.nix`) computes:

- **`topology`** -- Name, provider, node counts, network config, and which components are enabled
- **`sbom`** -- Software bill of materials (component versions)
- **`phases`** -- Merged phase bundles rendered as Nix store derivations
- **`phaseOrder`** -- Sorted list of phase names

```nix
# cluster.out.phases is computed by merging all bundles per phase
# and rendering them through lib/render.nix
config.cluster.out.phases = let
  mergePhase = phaseName: phaseCfg:
    let
      bundleValues = lib.attrValues phaseCfg.bundles;
      allHelmCharts = lib.foldl' (acc: b: acc // b.helmCharts) {} bundleValues;
      allResources  = lib.foldl' (acc: b: acc // b.resources) {} bundleValues;
      allYamls      = lib.concatMap (b: b.yamls) bundleValues;
    in
    render.renderPhase phaseName {
      helmCharts = allHelmCharts;
      resources  = allResources;
      yamls      = allYamls;
    };
in
  lib.mapAttrs mergePhase config.phases;
```

### Lab-Level `out`

`lab.out` (`modules/lab/out.nix`) computes:

- **`cliConfig`** -- JSON-serializable config that the Rust CLI needs (cluster names, services, DNS, registry, ops tool path)
- **`allClusters`** -- All evaluated cluster configs (used for cross-cluster references)
- **`manifests`** -- Per-cluster rendered manifest packages, passed through the strategy renderer
- **`package`** -- Single derivation combining all clusters' manifests with metadata

### Component-Level `ref`

Components use `ref` for their computed outputs. Unlike `out`, refs are always set (even when the component is disabled) so that other components can reference them safely:

```nix
config = lib.mkMerge [
  # Always set, regardless of enable state
  {
    components.tempo.ref = {
      namespace = cfg.namespace;
      otlpGrpc = "tempo-distributor.${cfg.namespace}.svc:4317";
      otlpHttp = "tempo-distributor.${cfg.namespace}.svc:4318";
    };
  }

  # Only writes to phases when enabled
  (lib.mkIf cfg.enable {
    phases.${cfg.phase}.bundles.tempo = { ... };
  })
];
```

## Avoiding Import From Derivation (IFD)

Import From Derivation (IFD) occurs when Nix needs to build a derivation during evaluation in order to import its output. IFD breaks parallelism, defeats caching, and makes evaluation unpredictable.

Catallaxy avoids IFD by keeping all configuration data as Nix expressions:

- Helm chart references are Nix store paths (fetched at flake lock time, not at eval time)
- Kubernetes API types are pre-generated Nix files committed to the repository
- Component configurations are pure Nix attrsets, not derived from external data

The only place derivations appear during evaluation is in `out` options that produce store paths for rendered manifests. These are `types.raw` or `types.package` options that Nix builds lazily -- they are not imported back into the evaluation.

## Module Evaluation Entry Points

The Rust CLI interacts with the Nix module system through two flake outputs:

### `clusters.<system>.<name>` (eval)

Returns a JSON-serializable representation of a cluster's configuration. The `lib/eval.nix:clusterConfigToJSON` function strips the evaluated config down to the fields the CLI needs.

### `labPackages.<system>."<name>"` (build)

Triggers a full build of the lab package, producing rendered manifests for all clusters. This is the primary entry point for `cata lab up` and `cata lab apply`.

The CLI uses `nix eval --json` for the first and `nix build --no-link --print-out-paths` for the second, keeping a clean separation between configuration inspection and manifest production.

## Nix-Specific Conventions

A few conventions specific to how Catallaxy uses the module system:

- **Do not use `mkIf` inside `resources` or `yamls` values.** Use `lib.optionalAttrs` or `if/then/else` instead. `mkIf` produces a NixOS module merge operation, which does not work inside attribute values that are passed directly to derivation builders.
- **Charts come from `cataCharts.<name>`**, defined in `lib/charts.nix`. Components accept a `chart` option so users can override the chart derivation.
- **Lab names support dots** (e.g., `homelab.local`). The CLI quotes them in nix eval: `labs.{system}."homelab.local"`.
- **All `ref` attributes are `readOnly`**, preventing users from accidentally overriding computed wiring values.

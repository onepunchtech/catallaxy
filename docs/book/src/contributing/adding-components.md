# Adding Components

Components are self-contained infrastructure units. Each component is a single Nix file that declares its configuration options and writes Kubernetes resources into phase bundles when enabled.

## Step 1: Create the component file

Create a new file at `modules/lab/cluster/components/<category>/<name>.nix`.

If the component fits an existing category (e.g., `observability`, `databases`, `pki`), place it there. If you need a new category, create a directory for it.

## Step 2: Write the component module

Follow this template:

```nix
{ config, lib, cataCharts, ... }:
let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.components.<name>;
in
{
  options.components.<name> = {
    enable = mkEnableOption "<Name>";

    phase = mkOption {
      type = types.str;
      default = "<phase>";
      description = "Deployment phase";
    };

    namespace = mkOption {
      type = types.str;
      default = "<namespace>";
    };

    chart = mkOption {
      type = types.package;
      default = cataCharts.<name>.chart;
      description = "Helm chart to use";
    };

    # Component-specific options go here

    ref = mkOption {
      type = types.attrs;
      readOnly = true;
      description = "Cross-component reference values";
    };
  };

  config = lib.mkMerge [
    # Computed refs -- always available, even when disabled.
    # This lets other components reference this component's values
    # without requiring it to be enabled.
    {
      components.<name>.ref = {
        namespace = cfg.namespace;
        # Add any values other components might need:
        # endpoint = "http://<name>.${cfg.namespace}.svc:8080";
      };
    }

    # Phase writer -- only active when enabled
    (mkIf cfg.enable {
      phases.${cfg.phase}.bundles.<name> = {
        createNamespaces = [ cfg.namespace ];

        helmCharts.<name> = {
          chart = cfg.chart;
          namespace = cfg.namespace;
          values = {
            # Helm values go here
          };
        };

        # Optional: typed Kubernetes resources
        # resources = { ... };

        # Optional: raw YAML manifests
        # yamls = [ ... ];
      };
    })
  ];
}
```

### Key conventions

- **`ref` is always set.** Even when the component is disabled, `ref` values must be available so other components can reference them without conditional checks.
- **`mkIf` is fine at the top level** (around the phase writer block), but do NOT use `mkIf` inside `resources` or `yamls` values. Use `optionalAttrs` or `if/then/else` instead.
- **Charts come from `cataCharts`**. Register your chart in `lib/charts.nix` first (see [Adding Charts](./adding-charts.md)), then reference it as `cataCharts.<name>.chart`.
- **CRDs go in the `crds` phase.** If your chart has CRDs, write them into a separate bundle:

```nix
(mkIf cfg.enable {
  phases.crds.bundles."<name>-crds".yamls = [ cataCharts.<name>.crds ];
  phases.${cfg.phase}.bundles.<name>.helmCharts.<name> = { ... };
})
```

## Step 3: Register the component

Add an import to the category's `default.nix`:

```nix
# modules/lab/cluster/components/<category>/default.nix
{ ... }:
{
  imports = [
    ./<existing-component>.nix
    ./<name>.nix  # add this line
  ];
}
```

## Step 4: Register a new category (if needed)

If you created a new category directory, add it to the top-level component registry:

```nix
# modules/lab/cluster/components/default.nix
{ ... }:
{
  imports = [
    ./backups
    ./cni
    # ...existing categories...
    ./<new-category>     # add this line
  ];
}
```

And create a `default.nix` in your new category directory:

```nix
# modules/lab/cluster/components/<new-category>/default.nix
{ ... }:
{
  imports = [
    ./<name>.nix
  ];
}
```

## Step 5: Verify

Run the full check suite:

```bash
nix flake check
```

This evaluates all example labs and runs lint, catching missing imports, type errors, and evaluation failures.

To inspect the rendered output:

```bash
nix build '.#labPackages.x86_64-linux."homelab.local"'
```

## Cross-component references

Components can reference other components via the `ref` attribute. This is how services wire together without hardcoding values:

```nix
{ config, ... }:
let
  certManagerRef = config.components.cert-manager.ref;
in
{
  # Use certManagerRef.caBundleConfigMap, certManagerRef.caBundleKey, etc.
}
```

For cross-cluster references, use the `lab` argument:

```nix
{ config, lab, ... }:
{
  components.otel-collector.exporters.otlp.endpoint =
    lab.clusters.obs.components.tempo.ref.otlpGrpc;
}
```

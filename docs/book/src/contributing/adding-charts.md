# Adding Charts

Helm charts are centrally managed in `lib/charts.nix`. Each chart is fetched at Nix evaluation time with a pinned version and integrity hash.

## Step 1: Add the chart definition

Open `lib/charts.nix` and add an entry to the `chartDefs` attribute set:

```nix
chartDefs = {
  # ... existing charts ...

  my-chart = {
    repo = "https://example.github.io/helm-charts";
    chart = "my-chart";
    version = "1.2.3";
    chartHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  };
};
```

### Required fields

| Field | Description |
|-------|-------------|
| `repo` | Helm repository URL. Supports `https://` and `oci://` prefixes. |
| `chart` | Chart name within the repository. |
| `version` | Exact chart version to fetch. |
| `chartHash` | SRI hash of the chart archive. Use a dummy value first, then fix it (see below). |

## Step 2: Get the chart hash

Set `chartHash` to an empty string or a dummy value, then build. Nix will report a hash mismatch and show the correct hash:

```bash
nix build .#cata 2>&1 | grep "got:"
```

Copy the `sha256-...` hash from the error output and paste it into `chartHash`.

## Step 3: Add CRDs (if applicable)

If the chart installs CRDs, add a `crd` attribute. There are three CRD source types:

### From the chart's `crds/` directory

```nix
my-chart = {
  repo = "...";
  chart = "my-chart";
  version = "1.2.3";
  chartHash = "sha256-...";
  crd = {
    type = "chart";
  };
};
```

### From a URL

```nix
my-chart = {
  # ...
  crd = {
    type = "url";
    url = "https://github.com/example/releases/download/v1.2.3/crds.yaml";
    hash = "sha256-...";
  };
};
```

### From a GitHub repository

```nix
my-chart = {
  # ...
  crd = {
    type = "github";
    owner = "example";
    repo = "my-project";
    rev = "v1.2.3";
    hash = "sha256-...";
    crdPath = "config/crd/bases";
  };
};
```

The `hash` for GitHub sources is the `fetchFromGitHub` hash. Use the same dummy-value-and-fix approach to obtain it.

## Step 4: Use the chart in a component

Reference the chart in your component module via `cataCharts`:

```nix
{ cataCharts, ... }:
{
  options.components.my-component = {
    chart = mkOption {
      type = types.package;
      default = cataCharts.my-chart.chart;
    };
  };

  config = mkIf cfg.enable {
    # Deploy CRDs in the crds phase
    phases.crds.bundles.my-component-crds.yamls = [ cataCharts.my-chart.crds ];

    # Deploy the chart in the appropriate phase
    phases.${cfg.phase}.bundles.my-component.helmCharts.my-component = {
      chart = cfg.chart;
      namespace = cfg.namespace;
      values = { ... };
    };
  };
}
```

The `cataCharts.<name>` attribute set provides:

| Attribute | Description |
|-----------|-------------|
| `chart` | The fetched chart derivation (passed to Helm) |
| `crds` | CRD derivation, or `null` if no CRDs are defined |
| `version` | Chart version string |

## Step 5: Verify

```bash
nix flake check
```

This ensures the chart fetches correctly and all labs that use it still evaluate.

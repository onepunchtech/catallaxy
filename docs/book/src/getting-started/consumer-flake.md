# Creating Your Own Lab

The example lab is bundled with catallaxy for reference, but real usage starts with your own flake. You define your lab topology in Nix modules and catallaxy evaluates them into rendered manifests and runtime tooling.

## Quick start

```bash
nix flake init -t github:onepunchtech/catallaxy#consumer
```

This creates a working consumer flake with a custom component example.

## Minimal flake

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    catallaxy.url = "github:onepunchtech/catallaxy";
  };

  outputs = { nixpkgs, flake-utils, catallaxy, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        mkLab = catallaxy.${system}.mkLab;
      in {
        labs."my-platform" = (mkLab {
          modules = [ ./lab.nix ];
        }).config.lab.out.cliConfig;
      }
    );
}
```

`mkLab` takes a list of NixOS-style modules and evaluates them through catallaxy's module system — the same one that powers the example labs.

## Define your lab topology

Create `lab.nix` alongside the flake:

```nix
{ config, lib, ... }:
{
  lab.name = "my-platform";
  lab.dns.zone = "mylab.test";

  lab.clusters.app = { ... }: {
    cluster.name = "app";
    cluster.kubernetes = {
      distribution = "k3s";
      controlPlanes = 1;
      workers = 0;
    };

    components.cert-manager.enable = true;
    components.gateway.enable = true;
  };
}
```

Each component is a self-contained module. Enabling it causes it to write its Helm charts, resources, and configuration into the appropriate deployment phase. The phase system handles ordering and dependencies.

## Custom components

Add your own components as modules:

```nix
mkLab {
  modules = [
    ./lab.nix
    ./components/my-app.nix    # Custom component
  ];
}
```

See [Writing Components](../extending/components.md) for the full guide.

## Splitting configuration across files

As your lab grows, split it into aspects (features), clusters, and environment overlays:

```nix
mkLab {
  modules = [
    ./topology.nix        # Cluster definitions
    ./networking.nix       # Gateway, DNS, cert-manager
    ./identity.nix         # Kanidm users, groups, OAuth2
    ./observability.nix    # Prometheus, Loki, Grafana
    ./env/local.nix        # Environment-specific overrides
  ];
};
```

This is the pattern the example lab uses: **aspects** define features, **clusters** compose aspects, and **environments** provide thin overrides for local, staging, or production targets.

## Cross-cluster references

Components can reference values from other clusters through the `lab` argument:

```nix
{ config, lab, ... }:
{
  components.otel-collector = {
    enable = true;
    exporters.otlp.endpoint = lab.clusters.obs.components.tempo.ref.otlpGrpc;
  };
}
```

Every component exposes a `ref` attribute set with computed, read-only values — endpoints, namespaces, service names. Refs are always available, even when the component is disabled.

## Running your lab

```bash
nix develop github:onepunchtech/catallaxy
cata --flake '.#my-platform' lab up
cata --flake '.#my-platform' lab down       # Stop (preserves state)
cata --flake '.#my-platform' lab destroy    # Delete everything
```

## Building manifests without applying

```bash
nix build '.#labPackages.x86_64-linux."my-platform"'
```

This produces the full deployment package — manifests, metadata, images list, and ops tooling — as a store path you can inspect, diff, or ship to CI.

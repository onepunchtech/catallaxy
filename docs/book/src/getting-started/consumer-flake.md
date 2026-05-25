# Creating Your Own Lab

The example lab is bundled with catallaxy for reference, but real usage starts with your own flake. You define your lab topology in Nix modules and catallaxy evaluates them into rendered manifests and runtime tooling.

## Minimal flake

Create a new directory for your lab and add a `flake.nix`:

```nix
{
  inputs = {
    catallaxy.url = "github:defectivenpc/catallaxy";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { catallaxy, nixpkgs, ... }:
  let
    lab = catallaxy.lib.mkLab {
      modules = [ ./lab.nix ];
    };
  in {
    # use lab outputs
  };
}
```

The key function is `catallaxy.lib.mkLab`. It takes a list of NixOS-style modules and evaluates them through catallaxy's module system — the same one that powers the example lab.

## Define your lab topology

Create `lab.nix` alongside the flake. This is where you declare clusters, enable components, and wire things together:

```nix
{ config, lib, ... }:
{
  lab = {
    name = "mylab";
    domain = "mylab.test";

    clusters.primary = {
      components = {
        cert-manager.enable = true;
        gateway.enable = true;
        argocd.enable = true;
      };
    };
  };
}
```

Each component is a self-contained module. Enabling it causes it to write its Helm charts, resources, and configuration into the appropriate deployment phase. You do not need to manage ordering or dependencies — the phase system handles that.

## Splitting configuration across files

As your lab grows, split it into multiple modules. The `modules` list in `mkLab` accepts any number of files, and the module system merges them:

```nix
lab = catallaxy.lib.mkLab {
  modules = [
    ./topology.nix        # cluster definitions
    ./networking.nix       # gateway, DNS, cert-manager config
    ./identity.nix         # kanidm users, groups, oauth2
    ./observability.nix    # prometheus, loki, grafana
    ./env/local.nix        # environment-specific overrides
  ];
};
```

This is the pattern the example lab uses: **aspects** define features (networking, identity, GitOps), **clusters** compose aspects, and **environments** provide thin overrides for local, staging, or production targets. No environment logic leaks into the aspects themselves.

## Cross-cluster references

Components can reference values from other clusters through the `lab` argument:

```nix
{ config, lib, lab, ... }:
{
  lab.clusters.apps = {
    components.otel-collector = {
      enable = true;
      exporters.otlp.endpoint =
        lab.clusters.obs.components.tempo.ref.otlpGrpc;
    };
  };
}
```

Every component exposes a `ref` attribute set with computed, read-only values — endpoints, namespaces, service names. These refs are always available, even when the referenced component is disabled, so your configuration does not break when toggling features.

## Running your lab

From your flake directory, enter the dev shell and use `cata` as shown in the [Quick Start](./quick-start.md):

```bash
nix develop github:defectivenpc/catallaxy
cata --flake .#mylab lab up
```

The `--flake .#mylab` argument points to the current directory's flake and selects the lab named `mylab` — the name you set in `lab.name`.

## Building manifests without applying

You can also build the rendered manifests as a Nix derivation without standing up any clusters:

```bash
nix build '.#labPackages.x86_64-linux."mylab"'
```

This produces the full deployment package — manifests organized by cluster and phase, metadata, and ops tooling — as a store path you can inspect, diff, or ship to a CI pipeline.

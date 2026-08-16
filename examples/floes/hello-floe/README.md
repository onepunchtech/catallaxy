# hello-floe

A minimal external **floe**, the catallaxy primitive for a composable,
testable, distributable Kubernetes payload.

This example demonstrates:

1. How to declare a floe from an external nix flake.
2. How to expose a typed `exports` interface downstream consumers can read
   with autocomplete and eval-time validation.
3. How to use the standard `overrides` escape hatch (annotations, labels,
   service type, node selector, tolerations) so cloud-provider specifics
   never bake into the floe body.
4. How to test a floe **in isolation** via `evalFloe`: no lab, no cluster,
   no other components required.

## Publish

Every flake output at `floes.<name>` is publishable. Push this repo to
github, tag a release, and consumers reference it as a normal flake input.

## Consume

```nix
# In a downstream lab's flake.nix:
{
  inputs = {
    catallaxy.url = "github:onepunchtech/catallaxy";
    hello.url    = "github:you/hello-floe";
  };

  outputs = { nixpkgs, flake-utils, catallaxy, hello, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        lab = catallaxy.legacyPackages.${system}.mkLab {
          modules = [
            hello.floes.hello       # ← import the external floe
            ({ ... }: {
              floes.hello = {
                enable = true;
                replicas = 3;
                overrides.extraLabels."app.kubernetes.io/instance" = "prod";
              };
            })
          ];
        };
      in
      {
        legacyPackages = {
          labs."my-lab.local" = lab.config.lab.out.cliConfig;
          labPackages."my-lab.local" = lab.config.lab.out.package;
        };
      });
}
```

Downstream floes read the interface:

```nix
{ config, ... }: {
  # This works with autocomplete because `exports` is a typed
  # submodule declared by hello-floe.
  helloUrl = config.floes.hello.exports.url;
}
```

## Test locally

```shell
nix flake check .
```

The `floe-hello-isolation` check runs `evalFloe` with a synthetic cluster
and asserts the floe produces the expected resources. No kubectl, no
cluster, no external dependencies.

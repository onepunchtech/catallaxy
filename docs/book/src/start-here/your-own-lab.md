# Build Your Own Lab

To create a lab just create a flake that uses the catallaxy module library
and expose it as output on your flake. Use the following or the example labs
as a starting point.

## Scaffold

```bash
mkdir my-platform && cd my-platform
nix flake init -t github:onepunchtech/catallaxy#consumer
```

Five files:

```
flake.nix                          catallaxy input, mkLab, outputs
lab.nix                            your topology
floes/default.nix                  your floe registry
floes/hello-world/default.nix      a worked example floe
floes/hello-world/options.nix      its option surface
```

## The flake

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
        lib = nixpkgs.lib;

        myFloes = import ./floes {
          inherit lib;
          inherit (catallaxy.lib.floe) mkFloe;
        };

        lab = catallaxy.legacyPackages.${system}.mkLab {
          modules = [ (import ./lab.nix { inherit myFloes; }) ];
        };
      in {
        legacyPackages = {
          labs."my-platform" = lab.config.lab.out.cliConfig;
          labPackages."my-platform" = lab.config.lab.out.package;
        };
      });
}
```

Two attribute paths are load-bearing, because they are what the CLI looks
for:

```
legacyPackages.<system>.labs.<lab-name>          the evaluated config
legacyPackages.<system>.labPackages.<lab-name>   the rendered manifests
```

`mkLab` is under `legacyPackages` (not `packages`) because a lab is not a
derivation and `nix flake check` would complain. The full surface is in
[Flake Outputs](../reference/flake-outputs.md).

`lab.nix` is a _function of_ your floe set. Module `imports` cannot depend
on `config`, because `imports` is resolved before the configuration exists,
so floes arrive as a closure argument rather than through `_module.args`.

## The lab

```nix
{ myFloes }:
{ ... }:
{
  lab.name = "my-platform";
  lab.dns.zone = "example.test";

  # Stated once, inherited by every floe's `gateway.tier`.
  lab.policy.exposure.defaultTier = "internal";

  lab.clusters.app =
    { lab, config, ... }:      # `config` is the CLUSTER; `lab` is the lab
    {
      imports = [ myFloes.hello-world ];

      cluster.name = "app";
      cluster.kubernetes = {
        distribution = "k3s";
        controlPlanes = 1;
        workers = 0;
      };

      floes.gateway.enable = true;
      floes.cert-manager.enable = true;

      floes.hello-world = {
        enable = true;
        domain = "hello.example.test";
        replicas = 2;
      };
    };
}
```

In this example we see that floes allow overriding options much like you
would provide values to template a helm chart.

## Run it

```bash
nix develop github:onepunchtech/catallaxy

cata --flake .#my-platform lab plan
cata --flake .#my-platform lab lint
cata --flake .#my-platform lab up
```

## Grow it

The template is one file because one cluster in one environment. Using NixOS
as an analagy when you define a NixOS configuration.nix it is for one host.
NixOS upstream options is for defining the universe of hosts. It has options
to define any possible host you want.

Here in Catallaxy we have one more level of abstraction. The module
definition is comparable to nixos's module. However we don't just want to
manage one single instance of a lab, we want multiple instances of labs. So
a lab definition can have multiple environments with which the lab can
reside. This can be up to you how you want to organize your lab's
environments, but in the examples the term is called an aspect. An aspect is
a grouping of functionality that can be imported into other nix expressions
like enviornment nix expressions.

```
labs/default.nix       what the platform IS       topology, ops commands
clusters/core.nix      what THIS cluster is       which capabilities run here
aspects/identity.nix   what ONE capability is     kanidm + everything it wires to
envs/prod.nix          WHERE it runs              provisioners, domains, credentials
```

A lab is then a base plus an environment:

```nix
allLabs = {
  "my-platform.local" = mkLab [ ./labs/default.nix ./envs/local.nix ];
  "my-platform.prod"  = mkLab [ ./labs/default.nix ./envs/prod.nix ];
};
```

Just keep in mind that there is a difference between the framework machinery
and the examples preferences on how to organize a lab. The example is just
that something you can borrow from to learn how to use the framework
machinery.

[`examples/labs/homelab`](https://github.com/onepunchtech/catallaxy/tree/master/examples/labs/homelab).

## Add checks early

The scaffold ships one:

```nix
checks.lab-eval =
  let forced = builtins.toJSON lab.config.lab.out.manifests;
  in pkgs.runCommand "lab-eval" { } ''
    cat > /dev/null <<'JSON'
    ${forced}
    JSON
    echo "my-platform evaluated" > $out
  '';
```

Forcing the manifest tree touches every option, so an unmet `requires`, a
bad `exports` read, or a broken anchor fails in CI rather than at `lab up`.
Add [plan snapshots](../understanding/how-it-works.md) next, they turn any
change in deploy ordering into a reviewable diff.

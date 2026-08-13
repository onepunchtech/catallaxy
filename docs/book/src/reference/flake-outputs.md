# Flake Outputs

Catallaxy's public surface. Get the attribute path from here rather than
guessing, most of the wrong incantations in circulation are variations on
`mkLab` living somewhere it does not.

## System-independent

### `nixosModules.default`

The whole module tree. `mkLab` uses it for you. You would only import it
directly to build a lab without `mkLab`.

### `nixosModules.hostDns`

A NixOS module that resolves a lab's zone through the lab's DNS container,
by writing the same systemd-resolved drop-in `cata lab dns --setup` writes
with sudo. Use it on a machine NixOS manages, where a `nixos-rebuild` would
otherwise revert what the command wrote.

```nix
imports = [ catallaxy.nixosModules.hostDns ];
services.resolved.enable = true;
services.catallaxy.hostDns = {
  enable = true;
  zones."minimal.test" = { host = "127.0.0.1"; port = 5354; };
};
```

`cata lab dns` prints this filled in for the lab, next to the sudo and
dnsmasq routes. Pick one: run `cata lab dns --teardown` before switching to
the module, so the file the command wrote does not sit beside the one Nix
manages.

### `lib`

```
lib.floe.mkFloe            author a floe
lib.floe.evalFloe          isolation-test a floe
lib.floe.refs              capability and reference types
lib.mkIdempotentJob        one-shot Jobs that survive re-apply
lib.hashContent            deterministic short hash of an attrset
lib.mkNetworkPolicy        NetworkPolicy builder
lib.mkPreserveRuntimePatches   kapp rebase rules
lib.network                CIDR arithmetic
lib.evalModule             the lab evaluator
```

This is the **stable API**. `modules/` is internal: configure through
options, do not import module files. `lib/eval/` and `lib/render/` are
internal too.

See [Nix Helpers](./helpers.md) and [mkFloe API](./floe-api.md).

### `templates.consumer`

```bash
nix flake init -t github:onepunchtech/catallaxy#consumer
```

A working lab plus a worked `mkFloe` example. See
[Build Your Own Lab](../start-here/your-own-lab.md).

## Per-system

### `legacyPackages` (where labs live)

```
legacyPackages.<system>.mkLab              evaluate a lab
legacyPackages.<system>.labs.<name>        the evaluated config  (cliConfig)
legacyPackages.<system>.labPackages.<name> the rendered manifests
legacyPackages.<system>.charts             the pinned chart set
legacyPackages.<system>.k8sTypegenConfig   input for `cata generate`
```

**`labs` and `labPackages` are the two the CLI resolves.** Your consumer
flake must expose them at exactly these paths:

```nix
legacyPackages = {
  labs."my-platform" = lab.config.lab.out.cliConfig;
  labPackages."my-platform" = lab.config.lab.out.package;
};
```

They are under `legacyPackages` rather than `packages` because a lab config
is not a derivation, and `nix flake check` warns about non-derivations under
`packages`.

```nix
mkLab { modules = [ … ]; } -> { config, options, ... }
```

The lab's own configuration hangs off `.config.lab.out.*`:

| Attribute                        | Is                                                                    |
| -------------------------------- | --------------------------------------------------------------------- |
| `cliConfig`                      | everything the CLI reads: clusters, plans, contexts, secrets metadata |
| `package`                        | the rendered manifest tree, hooks, lint checks, ops tool              |
| `manifests`                      | the manifest tree alone. Forcing it is the cheap eval check           |
| `deploymentPlan`, `teardownPlan` | ordered step lists, feed these to `lab plan --from-file`              |
| `allClusters`                    | per-cluster configs, including `assertions`                           |
| `runtimeContexts`                | the kube context an operator should use for each cluster right now    |

### `packages`

```
packages.<system>.default          the wrapped CLI
packages.<system>.cata             same
packages.<system>.cata-unwrapped   the bare binary, no tools on PATH
packages.<system>.option-docs      generated option markdown
packages.<system>.docs             the mdBook site
```

`cata` is wrapped in a `writeShellApplication` that puts kubectl, helm,
kapp, k3d, sops, crane and friends on PATH, so the binary never depends on
what happens to be installed.

### `apps`

```
nix run github:onepunchtech/catallaxy               # cata
nix run github:onepunchtech/catallaxy#generate-k8s-types
nix run .#<lab>-ops                                 # per lab with ops commands
```

### `devShells.default`

`cata`, `cata-dev`, every runtime tool, the Rust toolchain, and mdBook. See
[Install](../start-here/install.md).

### `checks`

`nix flake check` runs all of them.

| Group                  | What                                                                                                                                                        |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `cli`, `formatting`    | the binary builds. Treefmt is clean                                                                                                                         |
| `docs`, `docs-summary` | the book builds. Generated option pages match the nav                                                                                                       |
| `template-consumer`    | the scaffold still evaluates against the current API                                                                                                        |
| pure-Nix fixtures      | `plan-graph`, `manifest-graph`, `manifest-autoedges`, `k8s-helpers`, `wait-helpers`, `drift-lowering`, `mk-floe`, `floe-exports-defaults`, `contracts-oidc` |
| floe isolation         | `floe-<name>`, one per in-tree floe                                                                                                                         |
| out-of-tree proof      | `floe-hello`, `floe-consumer`                                                                                                                               |
| per example lab        | `<lab>-lint`, `<lab>-planner-assertions`, `plan-snapshot-<lab>-{deploy,teardown}`                                                                           |

See [How It Works](../understanding/how-it-works.md).

### `formatter`

`nix fmt`, treefmt with nixfmt, rustfmt, yamlfmt.

## Common mistakes

| Wrong                                 | Right                                                |
| ------------------------------------- | ---------------------------------------------------- |
| `catallaxy.${system}.mkLab`           | `catallaxy.legacyPackages.${system}.mkLab`           |
| `catallaxy.packages.${system}.mkLab`  | same                                                 |
| `labs.<system>.<name>`                | `legacyPackages.<system>.labs.<name>`                |
| `.#labPackages.x86_64-linux."<name>"` | `.#legacyPackages.x86_64-linux.labPackages."<name>"` |
| `catallaxy.lib.clusterConfigToJSON`   | does not exist                                       |
| `lib.types`                           | does not exist. Types live in `modules/`             |

# Floe API

A floe is an ordinary NixOS module. There is no constructor: what a floe
_is_ lives in two shared option modules that a floe imports,
`modules/lab/cluster/floe-options.nix` for a cluster floe and
`modules/lab/lab-floe-options.nix` for a lab floe.

`catallaxy.lib.floe` exports
`{ floeOptions, labFloeOptions, evalFloe, gatewayOptions, refs }`, declared
in `lib/floe/`.

## `floeOptions`

```nix
floeOptions { name, version ? null, drift ? [] }
  -> NixOS module declaring options.floes.<name>
```

| Argument  | Required | Meaning                                                              |
| --------- | -------- | -------------------------------------------------------------------- |
| `name`    | yes      | kebab-case. Becomes `options.floes.<name>` and the default namespace |
| `version` | no       | upstream version of the packaged software. Informational             |
| `drift`   | no       | default for `floes.<name>.drift.expected`                            |

A whole floe:

```nix
{ config, lib, ... }:

let
  inherit (catallaxy.lib.floe) floeOptions;
  cfg = config.floes.hello;
in
{
  imports = [
    (floeOptions {
      name = "hello";
      version = "1.29-alpine";
    })
    ./options.nix
  ];

  options.floes.hello = {
    replicas = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
    };

    exports.url = lib.mkOption {
      type = lib.types.str;
      default = "http://hello.hello.svc.cluster.local";
      description = "In-cluster URL of the Service.";
    };
  };

  config = lib.mkIf cfg.enable {
    floes.hello.exports.url = "http://hello.${cfg.namespace}.svc.cluster.local";
    floes.hello.bundles.hello.resources = { };
  };
}
```

`exports` is not special. It is a nested option like any other, so a floe
declares the fields it offers and a consumer reads
`config.floes.hello.exports.url`. A type error names the field.

Every field under `exports` needs a `default`, because a consumer may read
one while computing its own option default, which evaluates whether or not
this floe is enabled. Where there is no value until the floe runs, the
default is `null` and the type `nullOr`, so a consumer can still ask.
`checks.every-floe-export-has-a-default` reads every floe's exports with
nothing enabled and names any floe that cannot answer.

`./options.nix` is a plain module declaring more of `options.floes.<name>`;
splitting there is a convention, not a mechanism.

Nothing wraps the module body, so image retargeting, provenance and the rest
come from the option declarations rather than from a constructor having been
used. A floe that does not name `lab` in its formals still gets its images
retargeted, because `floeOptions` is what reads `lab`.

## `labFloeOptions`

```nix
labFloeOptions { name, version ? null }
  -> NixOS module declaring options.lab.floes.<name>
```

Same shape, minus `drift`. A lab floe aggregates cluster floes and whatever
is needed to aggregate them: it configures the lab and reaches down into
`lab.clusters.<c>`, and it has no namespace, no network intent, no drift and
no overrides, because none of those mean anything without a cluster.

A cluster floe reads a lab floe as `lab.floes.<x>.exports.<field>`, which is
the only thing of a lab floe that crosses the boundary. The reverse
direction is the lab floe writing into `lab.clusters.<c>` itself.

A lab floe that provisions clusters says so by exporting `clusters`. Nothing
registers as a platform; exporting that list is what makes one, and
`lab.platforms.contestedClusters` names any cluster two of them claim, which
every platform subtracts from the set it configures.

## Module arguments

A floe is a module, so it receives the module arguments its formals name:

```nix
{ config, lib, pkgs, k8sHelpers, ... }: { … }
```

| Argument     | Is                                                                                                                                                                            |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `config`     | the **cluster's** config, not the lab's                                                                                                                                       |
| `lab`        | the lab-scope allowlist: `floes`, `name`, `environment`, `contextPrefix`, `clusters`, `dns`, `network`, `registry`, `proxy`, `bgpRouter`, `secrets`, `images`, `cd`, `policy` |
| `cataCharts` | pinned chart derivations, `<name>.{chart,crds,version}`                                                                                                                       |
| `k8sSpecs`   | generated Kubernetes and CRD schemas                                                                                                                                          |
| `k8sHelpers` | `mkGatewayExposure`, `mkGatewayParentFor`, `mkHttpRoute`, `mkTlsRoute`, `mkCertificate`, `mkGatewayParent`, `wait.*`                                                          |
| `contracts`  | protocol contracts, currently `contracts.oidc`                                                                                                                                |

Another floe is read as `config.floes.<x>.exports.<field>`, its `exports`
and nothing else. Reaching past them takes a deliberate
`config.floes.<x>.<internal>`, which `checks.floe-boundary` rejects.

### Generated options

Every floe gets these at `options.floes.<name>`, on top of whatever it
declares itself, `exports` included:

| Option             | Type                     | Default                |
| ------------------ | ------------------------ | ---------------------- |
| `enable`           | bool                     | `false`                |
| `namespace`        | str                      | the floe's `name`      |
| `version`          | nullOr str               | the `version` argument |
| `drift.expected`   | listOf driftEntry        | the `drift` argument   |
| `overrides`        | submodule                | `{}`                   |
| `bundles`          | attrsOf bundle           | `{}`                   |
| `steps`            | attrsOf clusterStep      | `{}`                   |
| `ops`              | attrsOf (attrsOf opsCmd) | `{}`                   |
| `secrets.generate` | attrsOf generate         | `{}`                   |
| `verify`           | attrsOf check            | `{}`                   |
| `lint`             | attrsOf check            | `{}`                   |
| `images`           | attrsOf image            | `{}`                   |
| `network`          | submodule                | `{}`                   |
| `capabilities`     | submodule                | `{}`                   |

Everything a floe contributes is written under the floe and lifted by an
aggregator, so which floe a bundle, step, ops command or generated secret
came from is the key it was written under rather than a stamp applied
afterwards. Two enabled floes claiming one key is refused naming both.

A lab floe gets `enable`, `version`, `exports`, `steps`, `ops`, `lint` and
`verify`, lifted into `lab.steps`, `lab.ops.commands`, `lab.lint.checks` and
`lab.verify.checks` the same way.

`overrides` is the provider-specific escape hatch every floe carries:
`extraAnnotations`, `extraLabels` (attrsOf str), `serviceType` (enum
`ClusterIP` / `NodePort` / `LoadBalancer`), `nodeSelector` (attrsOf str),
`tolerations` (listOf attrs). Read them into every resource you emit.

A floe declares no dependencies of its own. What it needs is said on its
bundles, as names in the one dependency namespace, and mostly derived from
the resources it emits rather than written at all. Naming another floe would
name an implementation where the question is which job.

## `evalFloe`

```nix
evalFloe { floe, cluster ? {}, providers ? {}, args ? {} }
  -> { manifests, exports, config }
```

| Argument    | Meaning                                                                |
| ----------- | ---------------------------------------------------------------------- |
| `floe`      | the floe module                                                        |
| `cluster`   | extra config merged into the eval. Typically `floes.<n>.enable = true` |
| `providers` | stubbed upstream exports, wired in as `config.floes.<name>.exports`    |
| `args`      | extra `_module.args`, overriding the harness defaults                  |

`manifests` is the emitted `floes.<floe>.bundles.<name>` tree, lifted,
`config` the full evaluated config, and `exports` the floe's own exports
(populated only when exactly one floe is in the eval).

The harness supplies empty `cataCharts` and `k8sSpecs`, a `k8sHelpers` with
placeholder route and certificate constructors but the **real** wait
helpers, the real `contracts`, and a minimal `lab` record. The fixture
cluster declares `bundles`, `assertions`, `warnings`, `lifecycle`, `ops`,
`secrets.projections`, `resources`, `compose`, `databases` and `storage`.

See [Write a Floe](../using/writing-a-floe.md).

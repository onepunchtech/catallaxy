# mkFloe API

`catallaxy.lib.floe` exports `{ mkFloe, evalFloe, refs }`, declared in
`lib/floe/`.

## `mkFloe`

```nix
mkFloe { name, version ? null, exports ? {}, requires ? [],
         drift ? [], options ? {}, imports ? [], module }
  -> NixOS module function
```

| Argument   | Required | Meaning                                                               |
| ---------- | -------- | --------------------------------------------------------------------- |
| `name`     | yes      | kebab-case. Becomes `options.floes.<name>` and the default namespace  |
| `module`   | yes      | the body. Runs only when `cfg.enable`                                 |
| `exports`  | no       | the typed public interface. Every field must set a `default`          |
| `requires` | no       | floe _names_ that must also be enabled. Emits one assertion each      |
| `options`  | no       | extra options merged onto the standard set                            |
| `imports`  | no       | merged **outside** the enable gate: the `options.nix` split mechanism |
| `drift`    | no       | default for `floes.<name>.drift.expected`                             |
| `version`  | no       | upstream version of the packaged software. Informational              |

`exports` and `options` may each be an attrset of `mkOption`s or a
`{ lib, ... }:` function returning one.

The return value is a module _function_. In-tree floes capture their module
args and apply it (`(mkFloe {…}) __floeModuleArgs`); out-of-tree floes
export the function and let the consumer's module system apply the args.

### Module body arguments

`module` receives the standard module arguments plus `cfg` and `peers`:

```nix
module = { config, lib, pkgs, cfg, peers, k8sHelpers, ... }: { … }
```

| Argument     | Is                                                                                                                                                                   |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `cfg`        | `config.floes.<name>`, pre-resolved                                                                                                                                  |
| `peers`      | every _other_ floe's `exports`, and nothing else. The only sanctioned way to read one                                                                                |
| `config`     | the **cluster's** config, not the lab's                                                                                                                              |
| `lab`        | the lab-scope allowlist: `name`, `environment`, `contextPrefix`, `clusters`, `dns`, `network`, `registry`, `proxy`, `bgpRouter`, `secrets`, `images`, `cd`, `policy` |
| `cataCharts` | pinned chart derivations, `<name>.{chart,crds,version}`                                                                                                              |
| `k8sSpecs`   | generated Kubernetes and CRD schemas                                                                                                                                 |
| `k8sHelpers` | `mkHttpRoute`, `mkTlsRoute`, `mkCertificate`, `mkGatewayParent`, `wait.*`                                                                                            |
| `contracts`  | protocol contracts, currently `contracts.oidc`                                                                                                                       |

`peers.<x>` holds a peer's `exports` only. Reaching past it takes a
deliberate `config.floes.<x>.<internal>`, which `checks.floe-boundary`
rejects. Option _declarations_ run outside this scope, so `options.nix`
spells the same thing `config.floes.<x>.exports.<field>` and imports `refs`
and `contracts` directly.

### Generated options

Every floe gets these at `options.floes.<name>`:

| Option           | Type                     | Default                 |
| ---------------- | ------------------------ | ----------------------- |
| `enable`         | bool                     | `false`                 |
| `namespace`      | str                      | the floe's `name`       |
| `version`        | nullOr str               | the `version` argument  |
| `exports`        | submodule from `exports` | `{}`                    |
| `requires`       | listOf str, **readOnly** | the `requires` argument |
| `drift.expected` | listOf driftEntry        | the `drift` argument    |
| `overrides`      | submodule                | `{}`                    |

`overrides` is the provider-specific escape hatch every floe carries:
`extraAnnotations`, `extraLabels` (attrsOf str), `serviceType` (enum
`ClusterIP` / `NodePort` / `LoadBalancer`), `nodeSelector` (attrsOf str),
`tolerations` (listOf attrs). Read them into every resource you emit.

`requires` is readOnly and exists for introspection; the assertions are
wired at the `mkFloe` seam, not from the option value.

## `evalFloe`

```nix
evalFloe { floe, cluster ? {}, providers ? {}, args ? {} }
  -> { manifests, exports, config }
```

| Argument    | Meaning                                                                |
| ----------- | ---------------------------------------------------------------------- |
| `floe`      | the module returned by `mkFloe`                                        |
| `cluster`   | extra config merged into the eval. Typically `floes.<n>.enable = true` |
| `providers` | stubbed upstream exports, wired in as `config.floes.<name>.exports`    |
| `args`      | extra `_module.args`, overriding the harness defaults                  |

`manifests` is the emitted `bundles.<name>` tree, `config` the full
evaluated config, and `exports` the floe's own exports (populated only when
exactly one floe is in the eval).

The harness supplies empty `cataCharts` and `k8sSpecs`, a `k8sHelpers` with
placeholder route and certificate constructors but the **real** wait
helpers, the real `contracts`, and a minimal `lab` record. The fixture
cluster declares `bundles`, `assertions`, `warnings`, `lifecycle`, `ops`,
`secrets.projections`, `resources`, `compose`, `databases` and `storage`.

See [Write a Floe](../using/writing-a-floe.md).

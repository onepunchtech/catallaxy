# Lint Rules

`cata lab lint` checks the _rendered manifests_: the layer where types and
assertions cannot see anything, because a Service selector that matches no
pods is perfectly valid YAML. It needs no cluster.
[`lab verify`](./verify.md) is the counterpart that does, and checks a lab
that is already running.

```bash
cata --flake .#<lab> lab lint
cata lab lint --path ./result                    # an already-built package
cata --flake .#<lab> lab lint --skip prefix,image-pin
```

Exit code is non-zero if any diagnostic is an error. Warnings do not fail.

## What it checks

A run works through these layers, stopping at the first that fails:

| Layer         | Question                                |
| ------------- | --------------------------------------- |
| Environment   | are the tools this lab needs on `$PATH` |
| Configuration | does the lab configuration make sense   |
| Manifests     | are the rendered resources consistent   |

Diagnostics name the cluster, the rule that fired, the resource, and the
file it was rendered into, so an error is traceable back to the floe that
emitted it.

## Per-cluster rules

Run against each cluster's rendered resources, in this order.

| Rule          | Checks                                                                                          |
| ------------- | ----------------------------------------------------------------------------------------------- |
| `schema`      | every resource has `apiVersion`, `kind`, `metadata.name`                                        |
| `identity`    | no two resources share `(apiVersion, kind, namespace, name)`                                    |
| `prefix`      | non-CRD names and lab-owned namespaces carry `lab.prefix`                                       |
| `selector`    | every Service selector matches ≥1 workload pod template in the same namespace                   |
| `reference`   | ConfigMap and Secret references resolve, or are legitimately operator-managed at runtime        |
| `image-pin`   | enforces `lab.images.requireDigest` and `lab.images.allowedRegistries`                          |
| `crd-schema`  | validates custom resources against their CRD's OpenAPI v3 schema, types, enums, required fields |
| `missing-crd` | warns when a custom resource has no CRD in the cluster's manifest set                           |
| `ready-probe` | a bundle's `readyProbe` names something that bundle renders, or can mint after apply            |
| `assertions`  | surfaces Nix-declared `assertions` and `warnings` verbatim. A failed assertion is an error      |

`selector` earns its place: a one-character label typo produces a Service
with no endpoints. Valid YAML, clean apply, and it fails only when something
tries to reach it. `ready-probe` earns its place the same way: a probe
waiting on a resource nothing renders blocks until its timeout and then
fails the deploy, minutes later and far from the cause.

`assertions` carries no logic of its own: the constraint text lives in the
Nix module that knows the constraint. That is why the messages read like
advice rather than error codes.

## Lab-scope rules

Run after every cluster, with access to all clusters' resources plus the
deployment plan.

| Rule   | Checks                                                                                                      |
| ------ | ----------------------------------------------------------------------------------------------------------- |
| `plan` | no step names an undeclared cluster. No cluster created twice. No secret copied before both endpoints exist |

These catch what no per-cluster rule can: a copy step whose source cluster
renders no such Secret is invisible from either cluster alone.

## Custom checks

A lab declares its own, and they run alongside the built-ins:

```nix
lab.lint.checks.no-latest-tag = {
  description = "Container images must not use the floating `latest` tag";
  severity = "error";          # error | warning     (default warning)
  scope = "per-cluster";       # per-file | per-cluster  (default per-file)
  format = "json";             # exit-code | json    (default exit-code)
  command = ''
    find "$MANIFEST_DIR" -name '*.yaml' -print0 \
      | xargs -0 yq -o=json -I0 '.. | select(has("image")) | .image' 2>/dev/null \
      | grep -E ':latest"?$' \
      | jq -R '{severity: "error", resource: ., message: "image uses the `latest` tag"}' \
      | jq -s '.'
  '';
};
```

| `scope`       | Invoked            | Environment                 |
| ------------- | ------------------ | --------------------------- |
| `per-file`    | once per YAML file | `$FILE`, `$CLUSTER`         |
| `per-cluster` | once per cluster   | `$CLUSTER`, `$MANIFEST_DIR` |

`per-file` is simpler to write; `per-cluster` walks the tree itself and is
much cheaper on a large lab.

| `format`    | Contract                                                                                                        |
| ----------- | --------------------------------------------------------------------------------------------------------------- |
| `exit-code` | non-zero fails, stdout is the message                                                                           |
| `json`      | stdout is `[{severity, resource, message}]`, empty array passes, **exit code ignored**, severity per diagnostic |

Each check becomes a `writeShellApplication` with `yq`, `jq` and coreutils
on PATH, symlinked into the lab package at `$out/lint/<name>`. A check that
fails to _execute_ is reported as an error naming the check, rather than
being swallowed and reading as a pass.

## Skipping

Whole rules, for one run:

```bash
cata lab lint <lab> --skip prefix,image-pin,custom
```

`custom` skips every lab-declared check.

One resource, permanently, when a rule is genuinely wrong about it:

```yaml
metadata:
  annotations:
    catallaxy.io/lint-skip: reference,image-pin
```

Prefer the annotation over `--skip`: it is scoped, it is committed, and it
is visible next to the thing it excuses.

## In CI

Every example lab gets a check:

```nix
checks.<lab>-lint = pkgs.runCommand "<lab>-lint" {
  nativeBuildInputs = [ cata ];
} ''
  cata lab lint --path ${lab.config.lab.out.package}
  touch $out
'';
```

`--path` is what makes this sandbox-safe: the package is already a store
path, so the check never shells out to `nix eval`.

## A floe declares its own

A floe knows what a wrong rendering of itself looks like, so it says so once
rather than in every lab that enables it:

```nix
floes.gateway.lint.route-listener-exists = {
  description = "Every HTTPRoute attaches to a listener some Gateway declares";
  severity = "error";
  scope = "per-cluster";
  format = "json";
  command = builtins.readFile ./lint/route-listener-exists.sh;
};
```

The check runs on every cluster the floe is enabled on and nowhere else. Its
name in reports is `<floe>-<name>`, so two floes can call a check the same
thing.

This is the static counterpart to [`verify`](./verify.md): lint reads what
was rendered and needs no cluster, verify reads a running one.

Precedence when two of them share a name is floe, then lab, then cluster:
the narrower scope wins, because it is the one that knows about the
exception.

## Where the scripts land

`$out/lint/<cluster>/<name>`, one directory per cluster, because a floe's
check applies only where that floe is enabled.

A check that walks the manifest tree itself must use `find -L`. A wave
directory is a symlink into the store and `find` does not descend into one
without it, so a check without `-L` inspects nothing and passes.

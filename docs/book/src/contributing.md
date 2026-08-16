# Contributing

For changing catallaxy itself. Read
[How It Works](./understanding/how-it-works.md) first, since this page
assumes you know which of the three layers your change lands in.

```bash
git clone https://github.com/onepunchtech/catallaxy
cd catallaxy
nix develop
```

That gives you `cata` (the built CLI), `cata-dev` (builds and runs from
source), the Rust toolchain, mdBook, and every tool the CLI shells out to.

## The loop

```bash
cargo build                    # or `cata-dev <args>`
nix flake check                # the gate
nix fmt                        # treefmt: nixfmt, rustfmt, yamlfmt, prettier
```

`nix flake check` runs the CLI build, formatting, the pure-Nix fixtures,
every floe isolation check, per-lab lint and planner assertions, the plan
snapshots, and the book. It is not slow enough to skip.

| Changed                   | Run                                                            |
| ------------------------- | -------------------------------------------------------------- |
| a floe                    | `nix build .#checks.x86_64-linux.floe-<name>`                  |
| a graph or the planner    | `nix build .#checks.x86_64-linux.{plan,manifest}-graph`        |
| anything affecting a plan | `nix build .#checks.x86_64-linux.'plan-snapshot-<lab>-deploy'` |
| the CLI                   | `cargo test`, then `nix flake check`                           |
| docs                      | `nix build .#docs`                                             |
| anything a lab runs on    | stand one up: see below                                        |

Refresh a snapshot after an intentional ordering change:

```bash
cata --flake .#<lab> lab plan --stable [--teardown] \
  > examples/labs/tests/plan-snapshots/<lab>.<direction>.expected.txt
```

Read the diff before committing it. A refresh that reorders something you
did not intend to touch is the check doing its job.

## Conventions

**Functional flavour.** Data structures plus operations over them, rather
than long imperative bodies. Functions are `In → Out` mappings over
well-defined types.

**One purpose per file, under about 1000 lines.** Every source file opens
with a header of at most five lines saying what it is for. If the header
would be a list, the module is not cohesive. A file reduced below the limit
may not grow back past it.

**Comments explain why, never what.** Identifiers say what. A comment earns
its place by recording a non-obvious invariant, a constraint, or a
workaround, and for a workaround, recording the symptom and the date of the
incident that motivated it is house style, not clutter.

**Types live beside the module that owns them.** A type consumed from more
than one place does not belong in a `let`.

**No import-from-derivation.** Nothing in the evaluation path builds
something and then imports its output; IFD would make evaluation require a
build. The generated Kubernetes schemas are committed for this reason.

### Rust

Only `io/` performs I/O: `Command::new`, `std::fs`, `env::var` and `reqwest`
appear nowhere else. `commands/` is thin glue; logic that accumulates there
cannot be unit-tested or reused.

Parse `nix eval` JSON into a typed struct at the seam
(`io::nix::get_lab_spec`); downstream code takes `LabSpec`, not
`serde_json::Value`. A `.pointer("/foo/bar")` chain means a type is missing
at the edge.

Everything returns `anyhow::Result<T>`, with `.context()` saying what was
being attempted. There was a `CataError` enum for `io/` and domain to let
callers classify; nothing ever matched on a variant, so it was a message
prefix and it is gone. Reach for a typed error when a caller has to make a
decision from it, not before. Never `unwrap()` data from outside the
process.

### Nix

`lib/pure.nix` and what it re-exports is the **stable public API**; breaking
it needs a changelog note. `modules/`, `lib/eval/` and `lib/render/` are
internal.

## End to end

`nix flake check` never creates a cluster. `.github/workflows/e2e.yml` does:
it stands a lab up on a runner, runs `cata lab verify`, tears it down, and
asserts nothing survived. Two labs run on every pull request, and the two
expensive ones nightly.

Locally, the same thing, without GitHub:

```bash
nix run .#e2e -- minimal.local
```

That is the script CI runs, so the two cannot drift. It loads the lab's
`lab.secrets.envFile` if it declares one, brings the lab up, verifies it,
brings it up again to prove that changes nothing, tears it down, and asserts
nothing survived. Run it with no argument to see which labs it can stand up,
and the reason for each one it cannot.

`minimal.local` takes about 25 seconds and touches nothing but docker.
`gitops.local` takes about two minutes and wants `sudo` once, because
`publish-manifests` pushes to a git remote only the lab's DNS knows about.

Two labs can be up at once, but only if they do not want the same host
ports. Container names are derived from the lab name, so those never clash;
the ports are `lab.proxy.httpPort`, `lab.proxy.httpsPort`,
`lab.dns.hostPort` and `lab.registry.port`, and every example takes the
defaults. `cata lab up` checks the ports and the docker subnet before it
starts anything and says which to change.

The e2e script still refuses to run beside another lab, because it asserts
that nothing survives teardown and cannot tell your containers from its own.

Which labs CI runs is a hand-written list in the matrix at the top of
`e2e.yml`: `minimal.local` and `homelab.local`, on every trigger. Add a lab
to the list to have it tested.

Whether a lab _can_ run on a runner at all is still derived:

```bash
nix eval .#legacyPackages.x86_64-linux.e2eLabs --json | jq
```

A lab is eligible when every cluster is k3d, nothing provisions further
clusters, every managed secret lives in a `backend = "env"` store whose
values a committed `lab.secrets.envFile` supplies, and no step needs a
human. A sops store makes a lab ineligible: the runner holds no key, and
saying otherwise would move the failure from the eligibility output into the
middle of a CI run. `lib/tests/self-contained.nix` pins the answer for every
example, so the predicate cannot collapse to nothing without a test failing.

The two sides meet in the runner rather than in the workflow: `cata-e2e`
refuses a lab that is not eligible and prints the reasons, so a name in the
matrix that does not belong there fails loudly on its own job instead of
being silently dropped from a computed list.

Adding a lab that costs 39 image pulls to test one code path is the wrong
move; `examples/labs/gitops` exists because reaching the argocd handoff
through `homelab.gitops-local` costs that, and through a purpose-built lab
costs 12.

## Adding a plan step kind

A kind is one file at `modules/lab/planner/kinds/<kind>.nix`, registered in
that directory's `default.nix`. There is no auto-discovery.

It declares exactly five fields, and the schema emitter refuses a file that
declares any other set, so a new kind cannot skip a question:

```nix
{ lib }:
{
  directions = [ "deploy" ];       # which plans it may appear in
  idempotency = "idempotent";      # or "oneShot", "destructive"
  dialsLabEndpoints = false;       # does it reach a lab endpoint from the host
  dryRunSafe = false;              # may `--dry-run` execute it
  params.options = { };            # real mkOptions: types, defaults, descriptions
}
```

`params.options` is a flat attrset of options. It types
`lab.steps.<n>.params` for steps of this kind, so a misspelled or wrongly
typed param is an error at the option path the author wrote. No param may be
called `kind`: the wire format tags params with the step kind, and one named
`kind` would overwrite the tag.

Then add the matching `StepParams` variant and `StepKind` entry in the CLI,
and a handler in `cli/src/plan/steps/`. Refresh the conformance fixture:

```bash
nix build .#checks.x86_64-linux.step-kinds-conformance
```

That check regenerates `cli/tests/fixtures/step-kinds.json` from the
registry and diffs it; the tests in
`cli/src/domain/step_kind_conformance.rs` then assert the two sides agree on
every kind, param, requiredness, idempotency class, direction and dry-run
flag. The reference page in the book is generated from the same registry, so
there is no table to update.

## Adding a built-in floe

[Write a Floe](./using/writing-a-floe.md) applies unchanged. The extra
obligations for one that lives here:

**Register it.** There is no auto-discovery, so add the directory to
`modules/lab/cluster/floes/default.nix`. In-tree floes use the
trailing-application idiom, because `mkFloe` returns a module _function_ and
the floe needs its own captured module arguments:

```nix
{ config, lib, pkgs, cataCharts, k8sSpecs, k8sHelpers, ... }@__floeModuleArgs:
let inherit ((import ../../../../../lib/floe { inherit lib; })) mkFloe; in
(mkFloe { name = "<name>"; imports = [ ./options.nix ]; module = { cfg, ... }: { }; })
  __floeModuleArgs
```

**Pin the chart** in `lib/charts.nix` rather than taking one from elsewhere.
Set `chartHash` to a dummy value, build, and copy the hash from the mismatch
error. Add a `crd` attribute if the chart ships CRDs (`type` is `chart`,
`url` or `github`), and put the CRDs in their own bundle so consumers can
gate on them being established.

**Ship an isolation check** at `lib/tests/floes/<name>.nix`, registered as
`checks.floe-<name>`. Not optional.

**Ship a verify check** at `floes.<name>.verify.<check>` if the floe can say
something about itself that is true only when it works. Every lab enabling
the floe inherits it, so this is where e2e coverage comes from. See
[Verifying a Running Lab](./reference/verify.md), and note that `expect`
means "at least one": use `reject` for "all of them". If the floe declares
typed `exports`, add it to `lib/tests/floes/exports-defaults.nix` too,
because an export without a default breaks option-doc generation, a long way
from where you would look.

**Regenerate types** with `nix run .#generate-k8s-types` if the CRDs
changed, and commit the result.

## Docs

The book is mdBook plus generators. `mdbook serve` does **not** work
standalone: the mermaid assets, the option pages and the step-kind reference
are all injected at build time.

```bash
nix build .#docs && open result/index.html
nix build .#option-docs
```

`lib/docs/options.nix` evaluates the module tree and hands `nixosOptionsDoc`
output to the CLI's `docs render`, which routes each option to a page by
name. `lib/docs/step-kinds.nix` renders `reference/step-kinds.md` from the
kind registry. There is no hand-maintained category list, so adding a floe
adds a page with no edit to the generator, and an option matching no route
is a hard error rather than a silent drop. `checks.docs-options-nav` asserts
the generated page set matches `SUMMARY.md`.

Prose is formatted by prettier and wraps at 76 characters. Put identifiers
containing an underscore in backticks: prettier normalises emphasis to
underscores, so a bare `id_tokens` in a paragraph containing italics
corrupts both.

**Keep the book small.** It covers the model, how the system works, and the
two things a user does. Prefer improving those pages over adding new ones; a
page earns its place by being something a reader repeatedly needs and cannot
get from the generated reference.

## Pull requests

- **Small and incremental.** A refactor moves code without changing
  behaviour; a behaviour change is a separate pull request.
- **`nix flake check` and `cargo test` green.**
- **New files under about 1000 lines.**
- **`CHANGELOG.md` under `[Unreleased]`** for anything user-visible.
- **Snapshot refreshes reviewed, not rubber-stamped.**

## AI

Using AI is fine. Pull requests are judged by their content, not their
author, and everything above applies the same way.

Smaller pull requests are easier to understand and review. Pull requests
with tests that exercise the new feature or bugfix are easier to accept.

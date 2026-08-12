# Contributing conventions

Conventions this codebase is written toward. Apply them near your change.
Follow them from the start in new files.

Full versions, with rationale:

- [Contributing](docs/book/src/contributing.md)
- [Write a Floe](docs/book/src/using/writing-a-floe.md)

## Style

**Functional flavour.** Data structures plus operations over long imperative
bodies. Functions are `In → Out` mappings over well-defined types.

**≤1000 lines per file.** Once a file crosses this, split it. Prefer many
cohesive small modules to a few grab-bag modules.

**One purpose per file.** If a file cannot be described in one sentence, it
is not cohesive, split it.

**No comments.** Not in Nix, not anywhere. A comment is evidence the code
failed to say what it means, so fix the code: rename the binding, introduce
a type, split the function, or write an assertion whose failure message
carries the constraint. An assertion that fires beats a paragraph nobody
reads.

Reasoning that is genuinely worth keeping goes where it is searchable and
attached to a change: commit messages and `CHANGELOG.md`. Option
`description` strings are the exception: they are the API's documentation
and render into the options book.

This includes Rust `//`, `///` and `//!`. The only comments permitted
anywhere are toolchain directives (`# shellcheck disable=…`) and shebangs,
which are read by tools rather than people.

Clap help text is API surface, not commentary, so it is exempt for the same
reason option `description` strings are. Write it as explicit
`#[command(about = "…")]` and `#[arg(help = "…")]` attributes rather than
`///` doc comments, so that it is data a comment-stripping pass cannot
silently delete. Reuse across subcommands goes in a `const`. Every
subcommand gets an `about`; every argument whose meaning or default is not
obvious from its name gets a `help`.

## Rust (`cli/`)

### Hexagonal boundaries

```
domain/   pure: LabSpec, ClusterSpec, Plan, Diagnostic, ...
plan/     pure: LabSpec → Plan
lint/     pure: Manifests → Vec<Diagnostic>
codegen/  pure: OpenAPI/CRD → Nix
topology/ pure: LabSpec → topology renderings

io/       adapters: nix, kubectl, k3d, docker, ssa, talos
commands/ glue: parse args → call domain → drive io
```

- `Command::new`, `std::fs::*`, `env::var`, `reqwest::*` live only in `io/`.
- `domain/`, `plan/`, `lint/`, `codegen/`, `topology/` are pure.
- `commands/` is thin: parse arguments, load config via `io`, call domain
  functions, hand results to `io`. No business logic.

### Types at boundaries

Parse `nix eval` JSON into a typed struct at the seam (`io::nix::eval_lab`).
Downstream code takes `LabSpec`, not `serde_json::Value`.
`.pointer("/foo/bar")` chains are a smell.

### Errors

- `commands/` returns `anyhow::Result<T>`: the context is what the user
  sees.
- Domain and `io/` use `CataError` (a `thiserror` enum) so callers can
  classify: `Config`, `NixEval`, `ToolMissing`, `Manifest`, `Io`.
- Never `unwrap()` / `expect()` on data from outside the process.

### Testing

Unit tests colocated in the pure modules. Integration tests hit the `cata`
binary via `assert_cmd`.

## Nix (`lib/`, `modules/`)

### Public vs internal

- `lib/pure.nix` and what it re-exports is the **stable public API**.
  Breaking changes need a changelog note.
- `modules/` is **internal**. Consumers configure through options, not by
  importing module files.
- `lib/eval/` and `lib/render/` are internal. IR computation and output
  emission.

### File conventions

A file's purpose is carried by its path and its bindings, not a header
comment. If neither says what it is for, rename it or split it.

### Floes

A floe is `modules/lab/cluster/floes/<name>/{default.nix,options.nix}`,
registered in `modules/lab/cluster/floes/default.nix`. there is no
auto-discovery. Rules that bite if ignored:

- `options.nix` comes in through `mkFloe`'s `imports`, which sits
  **outside** the enable gate, so option declarations stay visible when the
  floe is off.
- Every `exports` field must set a `default`
  (`checks.floe-exports-defaults`), because a consumer may read one inside
  its own option default.
- Read `cfg.overrides.*` into every emitted resource.
- **Read peers only through `peers.<x>.<field>`**: their `exports`, and
  nothing else (`checks.floe-boundary`). What a floe does not export, you
  may not depend on; if you need a fact it keeps private, add it to that
  floe's `exports`. Publishing is the upstream floe's call. In
  `options.nix`, where there is no `peers`, spell it
  `config.floes.<x>.exports.<f>`.
- **Never ask a peer whether it is enabled.** `.enable` is its internal
  state and answers the wrong question. Ask for the capability,
  `peers.cert-manager.issuance != null`, which only the producer can
  compute. Two floes ANDing `trust-manager.enable` with
  `cert-manager.selfSignedCA.enable` is what put every CA-bundle consumer
  into a permanent `FailedMount` (2026-07-30).
- **Never hardcode a peer's readiness token.** Take it from the capability:
  `refs.needs peers.gateway.routing "publicReady"` in `requires`,
  `refs.orderAfter` in `after`. No capability, no edge.
- Consume nothing at `let` scope from outside the floe: a `let` binding
  evaluates even when the floe is disabled.
- Delegate manifest shapes to `k8sHelpers` rather than emitting inline.
- Ship an isolation check (`lib/tests/floes/<name>.nix`).

### Plan step kinds

A kind is `modules/lab/planner/kinds/<kind>.nix`, registered in that
directory's `default.nix`; there is no auto-discovery. It declares exactly
`directions`, `idempotency`, `dialsLabEndpoints`, `dryRunSafe` and
`params.options`, and the schema emitter refuses any other set of fields so
a new kind cannot skip a question. `params.options` is a flat attrset of
`mkOption`s and types `lab.steps.<n>.params`; no param may be called `kind`,
because the wire format tags params with the step kind.

A kind is also a `StepParams` variant and a `StepKind` entry in the CLI.
`checks.step-kinds-conformance` and
`cli/src/domain/step_kind_conformance.rs` hold the two sides together. The
book's Plan Step Kinds page is rendered from the registry by
`lib/docs/step-kinds.nix` at build time, so there is no table to update.

Plan anchors (`after`, `before`) resolve tokens and kinds only. A bare step
name is not an anchor. Build anchors with `lib.planTokens` (`needs`,
`wants`, `wantsAll`, `wantsKind`, `lab.*`, `cluster <name>`) rather than
interpolating strings.

### No import-from-derivation

Nothing in the eval path builds and then imports. Generated Kubernetes
schemas are committed, not derived at eval time.

### Types

Type definitions live beside the module that owns them.
`modules/lab/planner/types.nix`,
`modules/lab/cluster/lib/kubernetes/types.nix`. Do not define a type inline
in a `let` when it is consumed from more than one place.

## Vocabulary

Two words are overloaded. Keep them straight:

- **`exports`**: a floe's typed data interface
  (`floes.cert-manager.exports.defaultIssuerRef`).
- **`provides`**: a _bundle_'s readiness tokens for the install DAG
  (`[ "cert-manager/webhook/ready" ]`), and the same idea for plan steps.
- **`requires`**: floe _names_ on `mkFloe`, producing an assertion. On a
  bundle or step it is _tokens_, producing a DAG edge.

Phases are labels and directory prefixes. They do **not** determine install
order.

## PRs

- Small, incremental. A refactor PR moves code without changing behaviour. A
  behaviour change is separate.
- Every PR keeps `nix flake check` and `cargo test` green.
- New files ≤1000 lines. A reduced file may not re-cross 1000.
- Update `CHANGELOG.md` under `[Unreleased]` for user-visible changes.
- Review snapshot refreshes rather than rubber-stamping them.

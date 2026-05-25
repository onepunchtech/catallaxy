# Contributing Guide

## Setting up the development environment

All build tools are provided by the Nix dev shell:

```bash
nix develop
```

This gives you `cargo`, `talosctl`, `kubectl`, `kapp`, `helm`, `k3d`, and all other tools needed to build and test Catallaxy.

## Building

### Rust CLI

```bash
cd cli/
cargo build
cargo watch -x run   # rebuild on changes
```

### Full wrapped CLI (Nix)

```bash
nix build .#cata
```

The Nix-built binary includes all runtime tools in its PATH (kubectl, kapp, helm, etc.), so it works without entering the dev shell.

### Rendered manifests

```bash
nix build '.#labPackages.x86_64-linux."homelab.local"'
```

This evaluates the example lab modules and renders all Kubernetes manifests, which is useful for verifying that module changes produce correct output.

## Checking your work

### Full check suite

```bash
nix flake check
```

This runs:

- CLI build
- Nix formatting check (nixfmt)
- Rust formatting check (rustfmt)
- `cata lab lint` on all example labs

### Formatting

```bash
nix fmt
```

Formats all Nix, Rust, and YAML files. Run this before submitting changes.

## Code style

### Nix

- Minimal comments. Prefer clear naming and structure over inline documentation.
- Use `optionalAttrs` or `if/then/else` for conditional attribute values. Do NOT use `mkIf` inside values passed to `resources` or `yamls` -- it does not work as expected in that context.
- Components follow the single-file pattern: options and phase writer in one file. See [Adding Components](./adding-components.md).
- `ref` attributes are always `readOnly` and always set (even when the component is disabled).

### Rust

- Standard Rust conventions. Format with `rustfmt` (included in `nix fmt`).
- The CLI shells out to external tools (`nix eval`, `kapp`, `kubectl`, `helm`) rather than reimplementing their logic.

### General

- No auto-generated comments or boilerplate.
- Keep diffs small and focused.
- Test changes with `nix flake check` before submitting.

## Project structure

| Path | Description |
|------|-------------|
| `cli/src/` | Rust CLI source |
| `modules/lab/` | Lab-level Nix modules |
| `modules/lab/cluster/` | Cluster-level modules |
| `modules/lab/cluster/components/` | Component modules |
| `modules/lab/cluster/phases/` | Phase definitions |
| `lib/` | Shared Nix libraries (eval, render, charts) |
| `lib/renderers/` | Output strategies (kapp, argocd, fleet) |
| `examples/labs/` | Example lab configurations |
| `docs/` | Documentation (this mdBook site) |

## Testing

There are no traditional unit tests yet. The CLI has `assert_cmd` in dev-dependencies but no test files. Validation is done via `nix flake check`, which evaluates all example labs and runs `cata lab lint`.

To manually test changes:

1. Run `nix flake check` to verify the build and lint pass.
2. Build rendered manifests to inspect the output: `nix build '.#labPackages.x86_64-linux."homelab.local"'`
3. For runtime testing, stand up the example lab: `cata --flake ./examples/labs#homelab lab up`

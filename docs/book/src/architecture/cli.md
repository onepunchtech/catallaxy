# The Rust CLI

The `cata` binary is a Rust CLI built with [clap](https://docs.rs/clap) and [tokio](https://docs.rs/tokio). It handles all runtime operations: provisioning clusters, applying manifests, managing secrets and PKI, orchestrating backups, and bootstrapping CAPI management clusters.

The CLI does not contain any Kubernetes manifest logic. It delegates configuration evaluation and manifest rendering to Nix, then uses external tools (kubectl, kapp, k3d, sops, velero, clusterctl, ykman) to act on the results.

## Global Options

```
cata [OPTIONS] <COMMAND>

Options:
  --flake <FLAKE>    Flake reference (path, URL, or ref#name) [env: CATALLAXY_FLAKE] [default: .]
  -v, --verbose      Verbose output
```

The `--flake` flag specifies the Nix flake containing the lab/cluster configuration. The fragment after `#` (e.g., `./examples/labs#homelab.local`) is used as the default lab or cluster name for subcommands.

## How the CLI Interacts with Nix

The CLI communicates with the Nix layer through two mechanisms:

**`nix eval --json`** -- Used to read configuration without building anything. Returns cluster config, lab config, or cluster/lab name lists as JSON.

**`nix build --no-link --print-out-paths`** -- Used to build rendered manifests. Returns the Nix store path containing the built output.

The CLI resolves flake references (path + optional fragment) and constructs the correct attribute path for each operation. For example, `cata --flake ./examples/labs#homelab.local lab up` evaluates `labs.x86_64-linux."homelab.local"` and builds `labPackages.x86_64-linux."homelab.local"`.

## Runtime Dependencies

The CLI shells out to external tools that must be available in `PATH`. When built via `nix build .#cata`, all runtime tools are wrapped into the binary's path. Inside `nix develop`, they are provided by the dev shell.

Required tools: `nix`, `docker`, `kubectl`, `kapp`, `k3d`

Optional tools (command-specific): `sops`, `velero`, `clusterctl`, `ykman`, `certutil`, `gh`/`glab`

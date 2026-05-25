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

## Command Reference

### `cata lab` -- Multi-Cluster Environment Management

| Command | Description |
|---------|-------------|
| `lab list` | List all defined labs with cluster counts |
| `lab status [NAME]` | Show lab status: services (running/stopped) and clusters (ready/not ready) |
| `lab init [NAME]` | Initialize lab infrastructure: create Docker network, generate TLS certs, start services (DNS, registry, ingress), provision all clusters via k3d. Does not apply manifests. |
| `lab up [NAME]` | Full bootstrap: `init` + build lab package + import CA into clusters + apply manifests to all clusters in parallel |
| `lab down [NAME]` | Stop all clusters, stop services (except registry for cache), remove Docker network, remove CA from browser trust store |
| `lab apply [NAME]` | Build lab package and apply manifests to all clusters (without reprovisioning) |
| `lab lint [NAME]` | Build lab package and run structural lint checks (schema validation, identity checks, prefix completeness, selector matching, cross-references) |
| `lab publish [NAME]` | Build lab package and push rendered manifests to a git repository. Supports `--pr` for pull request creation (GitHub and GitLab). |
| `lab ops [ARGS...]` | Run the lab's ops tool -- component-aware shell scripts defined in `lab.ops.commands` |
| `lab dns [NAME]` | Show DNS setup instructions, or configure local DNS resolution with `--setup` / `--teardown` (supports macOS resolver files and Linux systemd-resolved) |
| `lab trust [NAME]` | Manage lab TLS CA trust. `--setup` adds the lab CA to the browser trust store (NSS on Linux, Keychain on macOS). `--teardown` removes it. `--export` prints the PEM to stdout. |

**Filtering options** for `lab up` and `lab apply`:

- `--phase <NAME>` -- Apply only a specific phase
- `--component <NAME>` -- Apply only a specific component
- `--dry-run` -- Show what would be deployed without applying

### `cata cluster` -- Single Cluster Management

| Command | Description |
|---------|-------------|
| `cluster list` | List all defined clusters with their provider |
| `cluster init [NAME]` | Provision a single cluster (creates k3d cluster if needed). Automatically starts lab services if the cluster belongs to a lab. |
| `cluster up [NAME]` | Provision and apply manifests (`init` + `apply`) |
| `cluster down [NAME]` | Stop and remove the cluster |
| `cluster status [NAME]` | Show cluster status: provider, node counts, runtime state |

### `cata apply` -- Direct Manifest Application

```
cata apply [OPTIONS]
```

Applies rendered manifests to a cluster. Supports kapp (direct apply), ArgoCD, and Fleet strategies. The strategy is determined by the cluster's `deploy.strategy` setting.

| Option | Description |
|--------|-------------|
| `--cluster <NAME>` | Target cluster |
| `--phase <NAME>` | Apply only a specific phase |
| `--component <NAME>` | Apply only a specific component |
| `--dry-run` | Show what would be deployed |
| `--sequential` | Deploy phases sequentially instead of the default parallel mode |

The apply process:

1. Resolves the Kubernetes context from provisioner config
2. Builds rendered manifests via `nix build` (unless pre-built path is provided by a lab command)
3. Discovers phases from the `.phase-order` file
4. For each phase in order: waits for required CRDs, injects SOPS secrets, deploys via kapp

### `cata pki` -- PKI Certificate Management

Manages a local CA and client certificates for passwordless Kubernetes authentication via X.509 certificates and YubiKey PIV slots.

| Command | Description |
|---------|-------------|
| `pki init [NAME]` | Create the CA for a cluster. Supports ECDSA P-256 and P-384. Configurable validity (default: 10 years). |
| `pki issue <USER>` | Issue a client certificate for a user. CN and organizations come from the cluster's `pki-auth.users` config. |
| `pki provision <USER>` | Write certificate and key to a YubiKey PIV slot via `ykman`. Configurable slot, touch policy, and PIN policy. |
| `pki list [NAME]` | Show CA and user certificate status (CN, expiry, YubiKey serial) |
| `pki kubeconfig <USER>` | Generate a kubeconfig entry for a user with embedded client certificate data |

State is stored in `~/.local/share/catallaxy/pki/<cluster>/`.

### `cata secrets` -- SOPS Secret Management

| Command | Description |
|---------|-------------|
| `secrets edit <FILE>` | Decrypt, edit in `$EDITOR`, and re-encrypt a SOPS-encrypted file |
| `secrets encrypt <FILE>` | Encrypt a plaintext file |
| `secrets decrypt <FILE>` | Decrypt a file to stdout |
| `secrets rotate <FILE>` | Rotate encryption keys |
| `secrets generate [CLUSTER]` | Generate values for managed secrets (random passwords, tokens) and encrypt with SOPS. Respects generator definitions in cluster config. |
| `secrets list [CLUSTER]` | List managed secrets and their status (generated, missing, operator-managed) |

Managed secrets are defined in cluster config with generators (e.g., `random-password`, `random-token`) and lengths. The `generate` command creates initial values and encrypts them. During `apply`, SOPS secrets are decrypted and injected as Kubernetes Secrets at the appropriate phase boundary.

### `cata backup` -- Velero Backup Management

| Command | Description |
|---------|-------------|
| `backup create` | Create a new backup with configurable namespace inclusion/exclusion |
| `backup list` | List backups |
| `backup describe <NAME>` | Show backup details |
| `backup logs <NAME>` | View backup logs |
| `backup delete <NAME>` | Delete a backup |
| `backup restore <BACKUP>` | Restore from a backup with optional namespace filtering |
| `backup restores` | List restores |
| `backup schedules` | List backup schedules |
| `backup trigger <SCHEDULE>` | Manually trigger a backup schedule |
| `backup stabilize` | Create a full backup before cluster operations (pivot, shutdown, upgrade) |
| `backup migrate --from <SRC> --to <DST>` | Migrate workloads between clusters via backup and restore. Both clusters must share a backup storage location. |

### `cata bootstrap` -- CAPI Management Cluster Bootstrap

Implements the Day 0 bootstrap sequence for Cluster API management clusters:

| Command | Description |
|---------|-------------|
| `bootstrap init <CLUSTER>` | Full bootstrap: create k3d bootstrap cluster, initialize CAPI, apply cluster manifests, wait for readiness, pivot CAPI resources to the new management cluster, apply components, clean up bootstrap cluster |
| `bootstrap resume <CLUSTER>` | Resume an interrupted bootstrap from the last completed step |
| `bootstrap cleanup` | Remove leftover bootstrap cluster and state |
| `bootstrap status` | Show bootstrap progress |

The bootstrap process is idempotent and crash-recoverable. State is persisted to `~/.cache/catallaxy/.cata-bootstrap-state.json` and each step checks whether it has already completed before executing.

Options for `bootstrap init`:
- `--no-pivot` -- Stop after cluster is ready without pivoting CAPI resources
- `--keep-bootstrap` -- Do not delete the k3d bootstrap cluster after pivot
- `--no-bootstrap` -- Skip component bootstrapping after pivot

### `cata kubeconfig` -- Kubeconfig Management

| Command | Description |
|---------|-------------|
| `kubeconfig show` | Show kubeconfig contexts for all clusters in a lab with reachability status |

### `cata generate` -- Kubernetes Type Generation

```
cata generate [CONFIG_FILE]
```

Generates Nix module types from Kubernetes OpenAPI specs and CRD YAML files. Takes a JSON config (from file or stdin) specifying:

- `outputDir` -- Where to write generated files
- `k8sVersions` -- Map of K8s version to OpenAPI spec path
- `crds` -- Map of CRD name to CRD YAML path

The generated types provide compile-time validation for Kubernetes resources defined in component modules. This command is wrapped by the `nix run .#generate-k8s-types` helper.

## How the CLI Interacts with Nix

The CLI communicates with the Nix layer through two mechanisms:

**`nix eval --json`** -- Used to read configuration without building anything. Returns cluster config, lab config, or cluster/lab name lists as JSON.

**`nix build --no-link --print-out-paths`** -- Used to build rendered manifests. Returns the Nix store path containing the built output.

The CLI resolves flake references (path + optional fragment) and constructs the correct attribute path for each operation. For example, `cata --flake ./examples/labs#homelab.local lab up` evaluates `labs.x86_64-linux."homelab.local"` and builds `labPackages.x86_64-linux."homelab.local"`.

## Runtime Dependencies

The CLI shells out to external tools that must be available in `PATH`. When built via `nix build .#cata`, all runtime tools are wrapped into the binary's path. Inside `nix develop`, they are provided by the dev shell.

Required tools: `nix`, `docker`, `kubectl`, `kapp`, `k3d`

Optional tools (command-specific): `sops`, `velero`, `clusterctl`, `ykman`, `certutil`, `gh`/`glab`

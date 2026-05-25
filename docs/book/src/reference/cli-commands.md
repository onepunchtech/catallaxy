# CLI Commands

The `cata` CLI orchestrates runtime operations for Catallaxy labs. It evaluates Nix expressions, applies manifests to clusters, and manages secrets, PKI, backups, and more.

Most commands require a `--flake` argument pointing to your lab flake:

```bash
cata --flake ./examples/labs#homelab.local <command>
```

## Lab lifecycle

### `cata lab up`

Provision all clusters in the lab, render manifests, and apply them phase by phase.

```bash
cata --flake ./examples/labs#homelab lab up
```

### `cata lab down`

Tear down all clusters in the lab and clean up resources.

```bash
cata --flake ./examples/labs#homelab lab down
```

### `cata lab init`

Initialize lab infrastructure without applying manifests. Sets up provisioners, generates PKI if needed, and prepares the environment.

```bash
cata --flake ./examples/labs#homelab lab init
```

### `cata lab status`

Show the status of all clusters and their components.

```bash
cata --flake ./examples/labs#homelab lab status
```

### `cata lab list`

List all labs defined in the flake.

```bash
cata --flake ./examples/labs lab list
```

### `cata lab lint`

Validate lab configuration. Evaluates the Nix modules and checks for errors without applying anything. This is what `nix flake check` runs.

```bash
cata --flake ./examples/labs#homelab lab lint
```

### `cata lab apply`

Apply manifests to all clusters in the lab. Unlike `lab up`, this does not provision clusters -- it only renders and applies.

```bash
cata --flake ./examples/labs#homelab lab apply
```

## Lab publishing

### `cata lab publish`

Render manifests and push them to a Git repository for GitOps consumption.

```bash
cata --flake ./examples/labs#homelab lab publish
cata --flake ./examples/labs#homelab lab publish --pr       # create a pull request
cata --flake ./examples/labs#homelab lab publish --dry-run  # render without pushing
```

## Local environment

### `cata lab dns`

Configure or remove local DNS resolution for lab domains.

```bash
cata --flake ./examples/labs#homelab lab dns --setup
cata --flake ./examples/labs#homelab lab dns --teardown
```

### `cata lab trust`

Install or remove the lab CA from the system trust store.

```bash
cata --flake ./examples/labs#homelab lab trust --setup
cata --flake ./examples/labs#homelab lab trust --teardown
```

## Lab ops

### `cata lab ops <command> [args...]`

Run lab-defined operational commands. These are custom scripts declared in the lab configuration that understand the lab topology.

```bash
cata --flake ./examples/labs#homelab lab ops init-user lab-admin
```

List available ops commands:

```bash
cata --flake ./examples/labs#homelab lab ops --list
```

## Cluster lifecycle

### `cata cluster up`

Provision a single cluster.

```bash
cata --flake ./examples/labs#homelab cluster up --cluster core
```

### `cata cluster down`

Tear down a single cluster.

```bash
cata --flake ./examples/labs#homelab cluster down --cluster core
```

### `cata cluster init`

Initialize a single cluster without applying manifests.

### `cata cluster status`

Show the status of a single cluster.

### `cata cluster list`

List all clusters in the lab.

## Apply

### `cata apply`

Apply manifests to a cluster with fine-grained control.

```bash
cata --flake ./examples/labs#homelab apply --cluster core
cata --flake ./examples/labs#homelab apply --cluster core --phase networking
cata --flake ./examples/labs#homelab apply --cluster core --component cert-manager
cata --flake ./examples/labs#homelab apply --cluster core --dry-run
```

Options:

| Flag | Description |
|------|-------------|
| `--cluster` | Target cluster name |
| `--phase` | Apply only a specific phase |
| `--component` | Apply only a specific component's bundles |
| `--dry-run` | Show what would be applied without making changes |

## PKI

### `cata pki root-ca`

Generate or display the root certificate authority.

```bash
cata pki root-ca --generate
cata pki root-ca --show
```

### `cata pki sign`

Sign a certificate with the root CA.

```bash
cata pki sign --cn "my-service" --san "my-service.example.com"
```

### `cata pki yubikey`

Manage YubiKey-backed PKI operations.

```bash
cata pki yubikey --setup
```

## Secrets

### `cata secrets generate`

Generate secrets for a lab (e.g., database passwords, OIDC client secrets).

```bash
cata --flake ./examples/labs#homelab secrets generate
```

### `cata secrets encrypt`

Encrypt secrets for storage.

```bash
cata secrets encrypt --file secrets.yaml
```

### `cata secrets decrypt`

Decrypt secrets for inspection or editing.

```bash
cata secrets decrypt --file secrets.yaml.enc
```

## Kubeconfig

### `cata kubeconfig sync`

Sync kubeconfig entries for all clusters in the lab.

```bash
cata --flake ./examples/labs#homelab kubeconfig sync
```

## Backup

### `cata backup create`

Create a Velero backup of a cluster.

```bash
cata --flake ./examples/labs#homelab backup create --cluster core
```

### `cata backup list`

List available backups.

```bash
cata --flake ./examples/labs#homelab backup list
```

### `cata backup restore`

Restore a cluster from a backup.

```bash
cata --flake ./examples/labs#homelab backup restore --cluster core --backup <name>
```

### `cata backup migrate`

Migrate a cluster to a new provider using backup and restore.

```bash
cata --flake ./examples/labs#homelab backup migrate --from core --to core-new
```

## Code generation

### `cata generate`

Generate Kubernetes API types from OpenAPI specs and CRDs. This is used during development of Catallaxy itself.

```bash
cata generate
```

Equivalent to `nix run .#generate-k8s-types`.

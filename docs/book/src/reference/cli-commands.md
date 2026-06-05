# CLI Commands

The `cata` CLI orchestrates runtime operations for Catallaxy labs. It evaluates Nix expressions, applies manifests to clusters, and manages secrets, PKI, and images.

Most commands require a `--flake` argument pointing to your lab flake:

```bash
cata --flake '.#homelab.local' <command>
```

## Lab Lifecycle

### `cata lab up`

Provision all clusters, render manifests, and apply them phase by phase.

```bash
cata lab up
```

### `cata lab down`

Stop lab clusters. Preserves state — clusters can be restarted with `lab up`.

```bash
cata lab down
```

### `cata lab destroy`

Destroy lab completely — deletes clusters, cloud resources, services, and network. Not reversible.

```bash
cata lab destroy
```

### `cata lab init`

Initialize lab infrastructure without applying manifests.

```bash
cata lab init
```

### `cata lab status`

Show the status of all clusters and services.

```bash
cata lab status
```

### `cata lab list`

List all labs defined in the flake.

```bash
cata lab list
```

### `cata lab plan`

Show the computed deployment plan without executing.

```bash
cata lab plan
cata lab plan --teardown   # show teardown plan
```

### `cata lab lint`

Validate rendered manifests against property checks.

```bash
cata lab lint
cata lab lint --skip image-pin,crd-schema   # skip specific checks
cata lab lint --path /nix/store/...-lab-*    # lint a pre-built package
```

### `cata lab apply`

Apply manifests to all clusters without provisioning.

```bash
cata lab apply
cata lab apply --phase operators   # specific phase
```

## Lab Publishing

### `cata lab publish`

Render manifests and push to a Git repository for GitOps consumption.

```bash
cata lab publish
cata lab publish --pr         # create a pull request
cata lab publish --dry-run    # preview without pushing
```

## Lab Ops

### `cata lab ops <args...>`

Run lab-defined operational commands.

```bash
cata lab ops idm init-user lab-admin
cata lab ops database shell
```

## Local Environment

### `cata lab dns`

Configure local DNS resolution for lab domains.

```bash
cata lab dns --setup
cata lab dns --teardown
```

### `cata lab trust`

Install or remove the lab CA from the system trust store.

```bash
cata lab trust --setup
cata lab trust --teardown
cata lab trust --export   # print CA PEM to stdout
```

## Cluster Lifecycle

### `cata cluster up`

Provision and apply manifests to a single cluster.

```bash
cata cluster up core
```

### `cata cluster down`

Stop a single cluster (alias: `cluster destroy`).

```bash
cata cluster down core
```

## Apply

### `cata apply <cluster>`

Apply manifests to a cluster with fine-grained control.

```bash
cata apply core
cata apply core --phase networking
cata apply core --dry-run
cata apply core --force   # bypass GitOps strategy check
```

## PKI

### `cata pki init`

Initialize the PKI CA for a cluster (generates root CA if needed).

```bash
cata pki init core
```

### `cata pki issue <user>`

Issue a client certificate for a user.

```bash
cata pki issue admin
```

### `cata pki provision <user>`

Write a certificate to a YubiKey PIV slot.

```bash
cata pki provision admin
```

### `cata pki list`

List CA and certificate status.

```bash
cata pki list core
```

### `cata pki kubeconfig <user>`

Generate a kubeconfig entry using the client certificate.

```bash
cata pki kubeconfig admin
```

## Secrets

### `cata secrets generate`

Generate SOPS-encrypted secret files for all stores.

```bash
cata secrets generate
```

### `cata secrets edit <store>`

Decrypt, edit, and re-encrypt a secrets store.

```bash
cata secrets edit cloud-creds
```

### `cata secrets decrypt <store>`

Decrypt a store to stdout.

```bash
cata secrets decrypt cloud-creds
```

### `cata secrets encrypt <file>`

Encrypt a plaintext file.

```bash
cata secrets encrypt secrets.yaml
cata secrets encrypt secrets.yaml --output secrets.enc.yaml
```

### `cata secrets rotate <store>`

Rotate encryption keys on a SOPS file.

```bash
cata secrets rotate cloud-creds
```

### `cata secrets list`

Show all stores, managed secrets, and projections.

```bash
cata secrets list
```

## Images

### `cata images list`

List all container images used by a lab.

```bash
cata images list
```

### `cata images mirror`

Mirror lab images to a target registry using crane.

```bash
cata images mirror --registry ghcr.io/my-org
cata images mirror --registry ghcr.io/my-org --dry-run
```

### `cata images prefetch`

Prefetch lab images into a local registry (e.g., Zot).

```bash
cata images prefetch --registry localhost:5050
```

## Kubeconfig

### `cata kubeconfig sync`

Sync kubeconfig entries for lab clusters.

```bash
cata kubeconfig sync
```

## Code Generation

### `cata generate`

Generate Kubernetes API types from OpenAPI specs and CRDs (development use).

```bash
nix run .#generate-k8s-types
```

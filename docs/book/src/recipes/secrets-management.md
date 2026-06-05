# Secrets Management

Catallaxy uses a three-layer model for secrets: **stores**, **managed secrets**, and **projections**.

## The Model

```
Stores          → Where encrypted values are stored (one SOPS file per store)
Managed Secrets → Source-of-truth keys that reference a store
Projections     → How managed secrets map to K8s Secrets per cluster/namespace
```

## Setup

### 1. Install SOPS and age

SOPS is included in the devshell. For age keys:

```bash
# Generate an age key (or use a YubiKey)
age-keygen -o ~/.config/sops/age/keys.txt

# For YubiKey:
age-plugin-yubikey  # Follow prompts to set up
```

### 2. Configure `.sops.yaml`

Create `.sops.yaml` at the repo root with creation rules matching your store paths:

```yaml
creation_rules:
  # Prod secrets — encrypt with your age key
  - path_regex: secrets/homelab\.prod/.*\.enc\.yaml$
    age: age1...your-public-key...

  # Local dev secrets
  - path_regex: secrets/homelab\.local/.*\.enc\.yaml$
    age: age1...your-public-key...
```

### 3. Declare stores and managed secrets

In your lab config:

```nix
# Stores — each becomes one SOPS file
lab.secrets.stores.cloud-creds = { backend = "sops"; };

# Managed secrets — source-of-truth keys
lab.secrets.managed = {
  do-token = {
    store = "cloud-creds";
    keys.token = { };         # Manual entry via secrets edit
  };
  cf-token = {
    store = "cloud-creds";
    keys.token = { };
  };
  db-password = {
    store = "cloud-creds";
    keys.password = {
      generator = "alphanumeric";  # Auto-generated
      length = 32;
    };
  };
};
```

### 4. Generate and edit secrets

```bash
# Generate SOPS files (creates placeholders, auto-generates where configured)
cata secrets generate

# Edit a store to fill in manual values
cata secrets edit cloud-creds

# List all secrets and their status
cata secrets list
```

## Projections

Projections map managed secrets into Kubernetes Secrets with optional transforms:

```nix
# In a cluster config:
secrets.projections.cloudflare-api-token = {
  source = "cf-token";           # From lab.secrets.managed
  namespace = "cert-manager";    # Target K8s namespace
  phase = "operators";           # Injected before this phase deploys
  keys.api-token.from = "token"; # Key mapping: K8s key ← managed key
};

secrets.projections.db-credentials = {
  source = "db-password";
  namespace = "forgejo";
  phase = "databases";
  keys = {
    password.from = "password";
    credentials = {
      from = "password";
      transform = "json-wrap";   # Wraps as {"password": "value"}
      jsonKey = "password";
    };
  };
};
```

### Transforms

| Transform | Description |
|-----------|-------------|
| `none` (default) | Passthrough — value as-is |
| `base64` | Base64-encode the value |
| `json-wrap` | Wrap as JSON: `{"<jsonKey>": "<value>"}` |

### Phase Ordering

Projections must be in a phase that runs **before or during** the phase of components that reference them. A Nix assertion validates this at build time:

```
Projection 'my-secret' is in phase 'infrastructure' (order 30)
but namespace 'my-ns' has components in phase 'operators' (order 10).
The secret won't exist when the component deploys.
```

The `projection-ref` lint check also validates that `secretKeyRef` names match declared projection names.

## Per-Environment Keys

Use different age keys per environment in `.sops.yaml`:

```yaml
creation_rules:
  - path_regex: secrets/.*\.prod/.*
    age: age1...prod-yubikey...

  - path_regex: secrets/.*\.staging/.*
    age: age1...staging-key...

  - path_regex: secrets/.*\.local/.*
    age: age1...dev-key...
```

## YubiKey Workflow

With `age-plugin-yubikey`, SOPS prompts for the YubiKey PIN during decryption. During `lab up`, secrets are decrypted once (during the `ensure-secrets` step) and cached in memory for all subsequent cluster deployments. This avoids repeated PIN prompts when Crossplane provisioning creates long gaps between cluster deploys.

## CLI Commands

```bash
cata secrets generate          # Generate SOPS files for all stores
cata secrets edit <store>      # Decrypt, edit, re-encrypt a store
cata secrets decrypt <store>   # Decrypt to stdout
cata secrets rotate <store>    # Rotate encryption keys
cata secrets list              # Show stores, managed secrets, and projections
```

# Example Labs

These example labs demonstrate catallaxy's capabilities across different environments.

## Local (`homelab.local`)

A fully self-contained lab that runs entirely on your machine using k3d. No cloud accounts or API keys required.

```bash
cata --flake '.#homelab.local' lab up
```

## Production Cloud (`homelab.prod`)

A multi-cluster lab on DigitalOcean with Cloudflare DNS. Requires API tokens and SOPS encryption setup.

### Prerequisites

1. **DigitalOcean account** with an API token ([create one here](https://cloud.digitalocean.com/account/api/tokens))
   - Permissions: Read + Write

2. **Cloudflare account** with a domain and an API token ([create one here](https://dash.cloudflare.com/profile/api-tokens))
   - Permissions: Zone:Read + DNS:Edit for your domain

3. **age key** for SOPS encryption (YubiKey or file-based)
   ```bash
   # File-based key:
   age-keygen -o ~/.config/sops/age/keys.txt
   # Copy the public key (age1...)
   ```

### Setup

#### 1. Configure SOPS

Create `.sops.yaml` at the repo root:

```yaml
creation_rules:
  - path_regex: secrets/homelab\.prod/.*\.enc\.yaml$
    age: age1...your-public-key...
```

#### 2. Update the DNS zone

Edit `examples/labs/envs/prod.nix` and set `lab.dns.zone` to your domain:

```nix
lab.dns.zone = "lab.yourdomain.com";
```

Update the ACME email and `domainFilters` in the same file.

#### 3. Generate and fill secrets

```bash
# Generate the SOPS file with placeholder values
cata --flake '.#homelab.prod' secrets generate

# Edit to fill in your API tokens
cata --flake '.#homelab.prod' secrets edit cloud-creds
```

The secrets file will open in your editor. Fill in:

```yaml
do-token:
  token: dop_v1_your_digitalocean_api_token
cf-token:
  token: cfat_your_cloudflare_api_token
```

Save and close — SOPS encrypts automatically.

#### 4. Deploy

```bash
cata --flake '.#homelab.prod' lab up
```

This will:
1. Create a local k3d management cluster
2. Install Crossplane with DO + CF providers
3. Provision DOKS clusters (core + obs) on DigitalOcean
4. Deploy all components to each cluster
5. Configure DNS records via Cloudflare
6. Issue TLS certificates via Let's Encrypt

#### 5. Verify

```bash
# Check cluster status
kubectl --context core get pods -A
kubectl --context obs get pods -A

# Reset a Kanidm user password
cata --flake '.#homelab.prod' lab ops idm init-user lab-admin
```

### Teardown

```bash
cata --flake '.#homelab.prod' lab down      # Stop (preserves state)
cata --flake '.#homelab.prod' lab destroy   # Delete everything (cloud resources too)
```

This deletes all cloud resources (DOKS clusters, DNS records) before destroying the local management cluster.

## Other Environments

- **`homelab.staging`** — staging overlay (shares topology with prod, different config)
- **`homelab.gitops-local`** — local lab with ArgoCD GitOps strategy

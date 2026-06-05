# Operational Runbook

## Lab Lifecycle

### Starting a Lab

```bash
cata lab up                    # Deploy everything
cata lab plan                  # Preview the deployment plan
cata lab plan --teardown       # Preview the teardown plan
```

### Updating a Lab

```bash
cata apply <cluster>                    # Apply all phases to a cluster
cata apply <cluster> --phase operators  # Apply a single phase
cata lab apply                          # Apply to all clusters in a lab
```

### Stopping a Lab

```bash
cata lab down         # Stop clusters (preserves state, restartable with lab up)
cata lab destroy      # Delete everything: clusters, cloud resources, services, network
```

## Troubleshooting

### ProgressDeadlineExceeded

**Symptom**: kapp reports a deployment stuck in `ProgressDeadlineExceeded` on re-runs.

**Cause**: A previous deploy failed (e.g., missing secret), leaving the deployment in a stale error state. On re-run, kapp sees no spec change (noop) and fails on the stale status.

**Fix**: The CLI auto-restarts stuck deployments before each kapp deploy. If the underlying issue is fixed (e.g., secret now exists), re-running `lab up` should resolve it automatically.

### Secret Not Found (CreateContainerConfigError)

**Symptom**: `CreateContainerConfigError: secret "X" not found`

**Possible causes**:

1. **Projection phase too late**: The secret projection is in a phase that runs after the component. Check with `cata lab lint` — the `projection-ref` check catches this.
2. **SOPS decryption failed**: YubiKey wasn't available or PIN wasn't entered. Check the `ensure-secrets` step output.
3. **Store file missing**: Run `cata secrets generate` then `cata secrets edit <store>`.

### ACME Certificate Not Issued

**Symptom**: Certificate stuck in `False` status, challenges pending.

**Check**:

```bash
kubectl get challenges -A
kubectl describe challenge <name> -n <ns>
```

**Common causes**:

- **API token missing Zone:Read**: Cloudflare token needs both `Zone:Read` and `DNS:Edit`
- **Wrong domain filter**: `domainFilters` must be the Cloudflare zone name (e.g., `praxioticsystems.com`), not a subdomain
- **DNS negative cache**: NXDOMAIN cached for 30 minutes (SOA minimum TTL). Wait or use a different resolver to verify.

### Crossplane Resource Not Ready

**Symptom**: `wait-for-resources` stuck, managed resources show `SYNCED=False`.

**Check**:

```bash
kubectl get managed                    # See all managed resources
kubectl describe <kind>/<name>         # Check status.conditions
kubectl get providerconfig             # Verify credentials
```

**Common causes**:

- **Wrong credentials**: Check the secret referenced by ProviderConfig
- **API quota exceeded**: DigitalOcean droplet limit reached
- **Provider not healthy**: `kubectl get providers` — check HEALTHY status

## Backup & Restore

### Creating a Backup

Velero schedules are configured per-cluster. To trigger a manual backup:

```bash
cata lab ops backup create
```

### Restoring from Backup

```bash
velero restore create --from-backup <backup-name>
```

### Checking Backup Status

```bash
velero backup get
velero schedule get
```

## Certificate Management

### ACME (Production)

Certificates are auto-renewed by cert-manager 30 days before expiry. No manual action needed.

To force renewal:

```bash
kubectl delete certificate <name> -n <ns>
# cert-manager will re-issue automatically
```

### Self-Signed CA (Local Dev)

The lab CA is generated during `lab up` and distributed via trust-manager. Certificates are valid for 1 year by default.

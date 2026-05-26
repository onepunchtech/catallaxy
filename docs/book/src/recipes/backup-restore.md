# Backup and Restore

Catallaxy uses [Velero](https://velero.io/) for cluster backup and restore. For local development, backups are stored in [SeaweedFS](https://github.com/seaweedfs/seaweedfs) (S3-compatible). For production, Velero supports AWS S3, GCP Cloud Storage, and Azure Blob Storage.

## Enabling backups

Enable Velero and a storage backend on the cluster that holds your stateful workloads:

```nix
# aspects/backups.nix
{ ... }:
{
  components.seaweedfs.enable = true;

  components.velero = {
    enable = true;
    local.enable = true; # SeaweedFS-backed storage for local dev
    schedules.daily = {
      schedule = "0 2 * * *";
      ttl = "168h"; # 7 days
    };
  };
}
```

Import this aspect in your cluster definition:

```nix
# clusters/core.nix
{
  imports = [
    ../aspects/networking.nix
    ../aspects/backups.nix
  ];
}
```

Deploy with `cata lab up` or `cata lab apply`. Velero will start taking scheduled backups automatically.

## Cloud storage (production)

For production, point Velero at a real S3 bucket instead of SeaweedFS:

```nix
components.velero = {
  enable = true;
  backupStorageLocation = {
    provider = "aws";
    bucket = "my-velero-backups";
    s3 = {
      region = "us-east-1";
      # For S3-compatible services (MinIO, Ceph, etc.):
      # endpoint = "https://s3.example.com";
      # s3ForcePathStyle = true;
    };
  };
};
```

Velero credentials are managed via a Kubernetes Secret in the `velero` namespace. Create it with SOPS or your preferred secret management approach.

## CLI commands

### On-demand backup

```bash
# Backup all namespaces (excludes kube-system, velero by default)
cata backup create --cluster core

# Backup specific namespaces
cata backup create --cluster core --namespaces forgejo,kanidm

# Backup with a custom name
cata backup create --cluster core --name pre-upgrade
```

### List and inspect

```bash
cata backup list --cluster core
cata backup describe --cluster core --name pre-upgrade
cata backup logs --cluster core --name pre-upgrade
```

### Restore

```bash
# Restore everything from a backup
cata backup restore --cluster core --backup pre-upgrade

# Restore specific namespaces only
cata backup restore --cluster core --backup pre-upgrade --namespaces forgejo
```

### Schedules

```bash
# List configured schedules
cata backup schedules --cluster core

# Manually trigger a schedule
cata backup trigger --cluster core --schedule daily
```

## Cross-cluster migration

Migrate workloads from one cluster to another. Both clusters must have Velero configured with access to the same backup storage.

```bash
# Migrate all workloads from core to core-v2
cata backup migrate --from core --to core-v2

# Migrate specific namespaces
cata backup migrate --from core --to core-v2 --namespaces forgejo,kanidm

# Skip confirmation prompt
cata backup migrate --from core --to core-v2 --yes
```

The migrate command creates a backup on the source cluster, restores it on the target, and prints next steps (DNS updates, ingress changes, source decommissioning).

## Pre-shutdown stabilization

Before tearing down a cluster, create a full backup:

```bash
cata backup stabilize --cluster core
```

This ensures all data is captured before the cluster is destroyed. The stabilize command will auto-deploy Velero if it isn't already running.

## Management cluster pivot

For CAPI-managed environments, `cata bootstrap init` handles the full management cluster lifecycle including pivot:

1. Creates a temporary bootstrap cluster
2. Provisions the management cluster via CAPI
3. Pivots CAPI resources from bootstrap to management cluster
4. Tears down the bootstrap cluster

The pivot is resumable — if it fails partway, `cata bootstrap resume` picks up where it left off.

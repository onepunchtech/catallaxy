# Backup and Restore

Catallaxy uses [Velero](https://velero.io/) for cluster backup and restore in it's example. However you can extend catallaxy to use whatever k8s backup strategy you want. For local development, backups are stored in [SeaweedFS](https://github.com/seaweedfs/seaweedfs) (S3-compatible). For production, Velero supports AWS S3, GCP Cloud Storage, and Azure Blob Storage.

## Enabling Backups

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

Deploy with `cata lab up` or `cata lab apply`. Velero will start taking scheduled backups automatically.

## Cloud Storage (Production)

For production, point Velero at a real S3 bucket:

```nix
components.velero = {
  enable = true;
  backupStorageLocation = {
    provider = "aws";
    bucket = "my-velero-backups";
    s3 = {
      region = "us-east-1";
    };
  };
};
```

## Using Velero

Backups are managed directly via the `velero` CLI or through lab ops commands.

### On-Demand Backup

```bash
# Via ops commands (if configured in your lab)
cata lab ops backup create

# Or directly via velero CLI
velero backup create my-backup --include-namespaces forgejo,kanidm
```

### List and Inspect

```bash
velero backup get
velero backup describe my-backup
velero backup logs my-backup
```

### Restore

```bash
velero restore create --from-backup my-backup
velero restore create --from-backup my-backup --include-namespaces forgejo
```

### Schedules

```bash
velero schedule get
velero schedule trigger daily
```

## Cross-Cluster Migration

Migrate workloads between clusters by backing up on one and restoring on another. Both clusters must have Velero configured with access to the same backup storage location.

```bash
# On source cluster
velero backup create migration-backup

# On target cluster
velero restore create --from-backup migration-backup
```

## Management Cluster Pivot

For environments with cloud management clusters, catallaxy handles the pivot automatically during `lab up` when a cluster self-provisions (declares itself in its own Crossplane `kubernetesClusters`). The planner generates bootstrap → pivot → destroy steps. See [Bootstrap & Pivot](../architecture/overview.md) for details.

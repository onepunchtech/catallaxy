# Backup and Restore

Backup is the `velero` floe. Enabling it gives a lab scheduled backups and a
set of `lab ops` commands for taking, listing and restoring them.

```nix
floes.velero = {
  enable = true;

  schedules.daily = {
    schedule = "0 2 * * *";
    ttl = "720h";
  };
};
```

Every option is in the generated
[velero reference](../reference/options/floes/velero.md). The rest of this
page is what that page cannot tell you.

## Schedules are declared, backups are taken

A schedule is a name plus a cron expression, and the lab may declare
several. `kube-system` and velero's own namespace are excluded by default,
because restoring either over a running cluster is not what you want.

```nix
floes.velero.schedules = {
  daily = {
    schedule = "0 2 * * *";
    ttl = "720h"; # 30 days
  };

  hourly-app = {
    schedule = "0 * * * *";
    ttl = "48h";
    includedNamespaces = [ "app" ];
    snapshotVolumes = true;
  };
};
```

`snapshotVolumes` needs a volume snapshotter from your storage provider.
Without one, set `defaultVolumesToFsBackup = true` to copy volume contents
through velero's file-system backup instead. Neither is the default for
every case, so decide per schedule.

## Taking and restoring

The commands come from the floe, so they exist only in a lab that enables
it. `lab ops` with no sub-command lists what yours offers.

```bash
cata --flake .#<lab> lab ops backup create              # name is generated
cata --flake .#<lab> lab ops backup create pre-upgrade  # or name it
cata --flake .#<lab> lab ops backup list
cata --flake .#<lab> lab ops backup describe pre-upgrade
cata --flake .#<lab> lab ops backup restore pre-upgrade
cata --flake .#<lab> lab ops backup delete pre-upgrade
```

Schedules have their own pair:

```bash
cata --flake .#<lab> lab ops backup schedules           # list them
cata --flake .#<lab> lab ops backup trigger daily       # run one now
```

`create` waits for the backup to finish, so a non-zero exit means the backup
did not complete and there is nothing to restore from. That makes it usable
as a step before a risky change:

```bash
cata lab ops backup create pre-upgrade && cata lab up
```

## What a restore does not cover

A velero restore rebuilds Kubernetes objects, and volume data when a
snapshotter or file-system backup is configured. It does not rebuild the
cluster itself, and it does not carry your secret stores: those live in
`lab.secrets` and are encrypted in your repository, which is where they
should be restored from. See [Secrets](./secrets.md).

The order for a lost cluster is therefore: `cata lab up` to get a cluster
and its floes back, then a velero restore for the workload state.

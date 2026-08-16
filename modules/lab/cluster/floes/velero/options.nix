{
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption types;

  backupScheduleType = types.submodule {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether this schedule is enabled";
      };

      schedule = mkOption {
        type = types.str;
        default = "0 2 * * *";
        description = "Cron schedule for backups";
      };

      ttl = mkOption {
        type = types.str;
        default = "720h";
        description = "Time to live for backups (e.g., 720h = 30 days)";
      };

      includedNamespaces = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Namespaces to include (empty = all)";
      };

      excludedNamespaces = mkOption {
        type = types.listOf types.str;
        default = [
          "kube-system"
          "velero"
        ];
        description = "Namespaces to exclude from backup";
      };

      includedResources = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Resources to include (empty = all)";
      };

      excludedResources = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Resources to exclude from backup";
      };

      includeClusterResources = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to include cluster-scoped resources";
      };

      snapshotVolumes = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to snapshot PVs (requires volume snapshotter)";
      };

      defaultVolumesToFsBackup = mkOption {
        type = types.bool;
        default = false;
        description = "Use file-system backup for volumes by default (restic/kopia)";
      };
    };
  };
in
{
  options.floes.velero = {
    chart = mkOption {
      type = types.package;
      default = cataCharts.velero.chart;
      description = "Velero Helm chart derivation (default: cataCharts.velero)";
    };

    backupStorageLocation = {
      provider = mkOption {
        type = types.enum [
          "aws"
          "gcp"
          "azure"
          "seaweedfs"
          "filesystem"
        ];
        default = "seaweedfs";
        description = "Backup storage provider";
      };

      bucket = mkOption {
        type = types.str;
        default = "velero-backups";
        description = "Bucket/container name for backups";
      };

      prefix = mkOption {
        type = types.str;
        default = "";
        description = "Prefix within the bucket for backups";
      };

      s3 = {
        region = mkOption {
          type = types.str;
          default = "seaweedfs";
          description = "S3 region";
        };

        endpoint = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "S3 endpoint URL";
        };

        s3ForcePathStyle = mkOption {
          type = types.bool;
          default = true;
          description = "Use path-style S3 URLs";
        };

        insecureSkipTLSVerify = mkOption {
          type = types.bool;
          default = false;
          description = "Skip TLS verification";
        };
      };

      credentialsSecret = mkOption {
        type = types.str;
        default = "velero-credentials";
        description = "Name of the secret containing storage credentials";
      };
    };

    volumeSnapshotLocation = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable volume snapshot location";
      };

      provider = mkOption {
        type = types.enum [
          "aws"
          "gcp"
          "azure"
          "csi"
        ];
        default = "csi";
        description = "Volume snapshot provider";
      };

      config = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Provider-specific configuration";
      };
    };

    fileSystemBackup = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable file system backups using restic/kopia";
      };

      uploaderType = mkOption {
        type = types.enum [
          "restic"
          "kopia"
        ];
        default = "kopia";
        description = "Uploader type for file system backups";
      };
    };

    schedules = mkOption {
      type = types.attrsOf backupScheduleType;
      default = {
        daily = {
          schedule = "0 2 * * *";
          ttl = "168h";
        };
        weekly = {
          schedule = "0 3 * * 0";
          ttl = "720h";
        };
      };
      description = "Named backup schedules";
    };

    local = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable local development mode using SeaweedFS";
      };
    };

    resources = {
      requests = {
        cpu = mkOption {
          type = types.str;
          default = "100m";
          description = "CPU the backup controller is guaranteed.";
        };
        memory = mkOption {
          type = types.str;
          default = "128Mi";
          description = "Memory the backup controller is guaranteed.";
        };
      };
      limits = {
        cpu = mkOption {
          type = types.str;
          default = "1000m";
          description = "CPU ceiling for the backup controller.";
        };
        memory = mkOption {
          type = types.str;
          default = "512Mi";
          description = "Memory ceiling. A backup of a large cluster is the case that pushes this.";
        };
      };
    };
  };
}

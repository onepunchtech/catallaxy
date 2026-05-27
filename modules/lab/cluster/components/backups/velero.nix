{
  config,
  lib,
  pkgs,
  cataCharts,
  ...
}:

let
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    mapAttrs'
    nameValuePair
    optionalAttrs
    optional
    ;
  cfg = config.components.velero;
  seaweedCfg =
    config.components.seaweedfs or {
      enable = false;
      ref = { };
    };

  # When using local SeaweedFS storage, Velero must deploy after SeaweedFS
  veleroPhase = if cfg.local.enable then "apps" else cfg.phase;
  schedulesPhase = if cfg.local.enable then "workloads" else "infrastructure";

  # Chart reference with fallback
  chartRef = cfg.chart;

  # Kube context for ops scripts (provided by provisioner modules)
  kubeContext = config.cluster.ref.kubeContext;

  # Ops helper scripts
  mkVeleroScript =
    name: text:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = with pkgs; [
        kubectl
        velero
      ];
      text = ''
        KUBE_CONTEXT="${kubeContext}"
        ${text}
      '';
    };

  # Backup schedule submodule
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

  # Determine the actual provider for BackupStorageLocation
  bslProvider =
    if cfg.backupStorageLocation.provider == "seaweedfs" then
      "aws"
    else
      cfg.backupStorageLocation.provider;

  # Build S3 config for BackupStorageLocation
  s3Config =
    optionalAttrs
      (cfg.backupStorageLocation.provider == "aws" || cfg.backupStorageLocation.provider == "seaweedfs")
      {
        region = cfg.backupStorageLocation.s3.region;
      }
    // optionalAttrs (cfg.backupStorageLocation.s3.endpoint != null) {
      s3Url = cfg.backupStorageLocation.s3.endpoint;
    }
    // optionalAttrs cfg.backupStorageLocation.s3.s3ForcePathStyle {
      s3ForcePathStyle = "true";
    }
    // optionalAttrs cfg.backupStorageLocation.s3.insecureSkipTLSVerify {
      insecureSkipTLSVerify = "true";
    };

  # Build Helm values
  helmValues = {
    snapshotsEnabled = cfg.volumeSnapshotLocation.enable;
    configuration = {
      backupStorageLocation = [
        {
          name = "default";
          provider = bslProvider;
          bucket = cfg.backupStorageLocation.bucket;
          prefix = cfg.backupStorageLocation.prefix;
          config = s3Config;
          credential = {
            name = cfg.backupStorageLocation.credentialsSecret;
            key = "cloud";
          };
        }
      ];

      volumeSnapshotLocation = optional cfg.volumeSnapshotLocation.enable {
        name = "default";
        provider = cfg.volumeSnapshotLocation.provider;
        config = cfg.volumeSnapshotLocation.config;
      };

      uploaderType = cfg.fileSystemBackup.uploaderType;
      defaultVolumesToFsBackup = cfg.fileSystemBackup.enable;
    };

    resources = {
      requests = cfg.resources.requests;
      limits = cfg.resources.limits;
    };

    deployNodeAgent = cfg.fileSystemBackup.enable;
    installCRDs = false;
    upgradeCRDs = false;

    credentials = {
      useSecret = true;
      existingSecret = cfg.backupStorageLocation.credentialsSecret;
    };

    # Velero plugins as init containers
    initContainers =
      optional
        (
          cfg.backupStorageLocation.provider == "aws"
          || cfg.backupStorageLocation.provider == "seaweedfs"
        )
        {
          name = "velero-plugin-for-aws";
          image = "velero/velero-plugin-for-aws:v1.11.1";
          imagePullPolicy = "IfNotPresent";
          volumeMounts = [
            {
              mountPath = "/target";
              name = "plugins";
            }
          ];
        };
  };

  # Local mode configuration using SeaweedFS
  localS3Config = optionalAttrs cfg.local.enable {
    configuration.backupStorageLocation = [
      {
        name = "default";
        provider = "aws";
        bucket = cfg.backupStorageLocation.bucket;
        config = {
          region = cfg.backupStorageLocation.s3.region;
          s3Url = seaweedCfg.ref.s3Endpoint or "http://seaweedfs-s3:8333";
          s3ForcePathStyle = "true";
          insecureSkipTLSVerify = "true";
        };
        credential = {
          name = cfg.backupStorageLocation.credentialsSecret;
          key = "cloud";
        };
      }
    ];
  };

  # Generate Schedule CRs
  scheduleResources = mapAttrs' (
    name: schedule:
    nameValuePair "schedule-${name}" {
      apiVersion = "velero.io/v1";
      kind = "Schedule";
      metadata = {
        inherit name;
        namespace = cfg.namespace;
        labels = {
          "app.kubernetes.io/managed-by" = "catallaxy";
        };
      };
      spec = {
        schedule = schedule.schedule;
        paused = !schedule.enable;
        template = {
          ttl = schedule.ttl;
          includedNamespaces =
            if schedule.includedNamespaces == [ ] then null else schedule.includedNamespaces;
          excludedNamespaces =
            if schedule.excludedNamespaces == [ ] then null else schedule.excludedNamespaces;
          includedResources = if schedule.includedResources == [ ] then null else schedule.includedResources;
          excludedResources = if schedule.excludedResources == [ ] then null else schedule.excludedResources;
          includeClusterResources = schedule.includeClusterResources;
          snapshotVolumes = schedule.snapshotVolumes;
          defaultVolumesToFsBackup = schedule.defaultVolumesToFsBackup;
          storageLocation = "default";
        };
      };
    }
  ) cfg.schedules;

  # SeaweedFS resources for local mode
  seaweedResources = optionalAttrs cfg.local.enable {
    "velero-bucket-init" = {
      apiVersion = "batch/v1";
      kind = "Job";
      metadata = {
        name = "velero-bucket-init";
        namespace = cfg.namespace;
        labels = {
          app = "velero-bucket-init";
          "app.kubernetes.io/managed-by" = "catallaxy";
        };
      };
      spec = {
        backoffLimit = 10;
        template = {
          metadata.labels.app = "velero-bucket-init";
          spec = {
            restartPolicy = "OnFailure";
            containers = [
              {
                name = "aws-cli";
                image = "amazon/aws-cli:latest";
                env = [
                  {
                    name = "AWS_ACCESS_KEY_ID";
                    value = "any";
                  }
                  {
                    name = "AWS_SECRET_ACCESS_KEY";
                    value = "any";
                  }
                ];
                command = [
                  "/bin/sh"
                  "-c"
                ];
                args = [
                  ''
                    until aws --endpoint-url ${
                      seaweedCfg.ref.s3Endpoint or "http://seaweedfs-s3:8333"
                    } s3 ls 2>/dev/null; do
                      echo "Waiting for SeaweedFS S3..."
                      sleep 5
                    done
                    aws --endpoint-url ${
                      seaweedCfg.ref.s3Endpoint or "http://seaweedfs-s3:8333"
                    } s3 mb s3://${cfg.backupStorageLocation.bucket} --region ${cfg.backupStorageLocation.s3.region} || true
                    echo "Bucket ${cfg.backupStorageLocation.bucket} ready"
                  ''
                ];
              }
            ];
          };
        };
      };
    };

    "${cfg.backupStorageLocation.credentialsSecret}" = {
      apiVersion = "v1";
      kind = "Secret";
      metadata = {
        name = cfg.backupStorageLocation.credentialsSecret;
        namespace = cfg.namespace;
        labels = {
          "app.kubernetes.io/managed-by" = "catallaxy";
        };
      };
      type = "Opaque";
      stringData = {
        cloud = ''
          [default]
          aws_access_key_id = seaweedfs
          aws_secret_access_key = seaweedfs
        '';
      };
    };
  };

in
{
  # =========================================================================
  # PART 1: High-level options
  # =========================================================================

  options.components.velero = {
    enable = mkEnableOption "Velero backup and restore";

    phase = mkOption {
      type = types.str;
      default = "operators";
      description = "Deployment phase this component belongs to";
    };

    version = mkOption {
      type = types.str;
      default = "7.2.1";
      description = "Velero Helm chart version";
    };

    chart = mkOption {
      type = types.package;
      default = cataCharts.velero.chart;
      description = "Velero Helm chart derivation (default: cataCharts.velero)";
    };

    namespace = mkOption {
      type = types.str;
      default = "velero";
      description = "Namespace for Velero";
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
        };
        memory = mkOption {
          type = types.str;
          default = "128Mi";
        };
      };
      limits = {
        cpu = mkOption {
          type = types.str;
          default = "1000m";
        };
        memory = mkOption {
          type = types.str;
          default = "512Mi";
        };
      };
    };

    ref = mkOption {
      type = types.attrs;
      readOnly = true;
      description = "Computed references for Velero";
    };
  };

  # =========================================================================
  # PART 2: Computed refs and config
  # =========================================================================

  config = lib.mkMerge [
    {
      components.velero.ref = {
        namespace = cfg.namespace;
      };
    }

    (mkIf cfg.enable {
      # Assertions
      assertions = [
        {
          assertion = !cfg.local.enable || (seaweedCfg.enable or false);
          message = "Velero local mode requires SeaweedFS to be enabled";
        }
      ];

      # Install Velero CRDs in the crds phase (before operators)
      phases.crds.bundles.velero-crds.yamls = [ cataCharts.velero.crds ];

      phases.${veleroPhase}.bundles.velero = {
        # Velero helm chart
        helmCharts.velero = {
          chart = chartRef;
          releaseName = "velero";
          namespace = cfg.namespace;
          createNamespace = true;
          values = helmValues // localS3Config;
        };

        # SeaweedFS resources (Secrets/Jobs don't need CRDs)
        resources = seaweedResources;

        # Namespace creation
        createNamespaces = [ cfg.namespace ];
      };

      # Schedule CRs go in a later phase so Velero CRDs are established first
      phases.${schedulesPhase}.bundles.velero-schedules = {
        resources = scheduleResources;
      };

      # Ops commands for lab CLI (category = subcommand group)
      ops.create = {
        description = "Create a Velero backup";
        category = "backup";
        options.cluster = {
          type = "enum";
          values = [ config.cluster.name ];
          required = true;
          description = "Target cluster";
        };
        args = [
          {
            name = "name";
            description = "Backup name (optional, auto-generated if omitted)";
            required = false;
          }
        ];
        package = mkVeleroScript "create" ''
          NAME="''${1:-$(date +%Y%m%d-%H%M%S)}"
          velero backup create "$NAME" \
            --kubecontext "$KUBE_CONTEXT" \
            --exclude-namespaces kube-system,${cfg.namespace} \
            --include-cluster-resources=true \
            --wait
        '';
      };

      ops.list = {
        description = "List Velero backups";
        category = "backup";
        options.cluster = {
          type = "enum";
          values = [ config.cluster.name ];
          required = true;
          description = "Target cluster";
        };
        package = mkVeleroScript "list" ''
          velero backup get --kubecontext "$KUBE_CONTEXT"
        '';
      };

      ops.describe = {
        description = "Describe a Velero backup";
        category = "backup";
        options.cluster = {
          type = "enum";
          values = [ config.cluster.name ];
          required = true;
          description = "Target cluster";
        };
        args = [
          {
            name = "name";
            description = "Backup name";
          }
        ];
        package = mkVeleroScript "describe" ''
          velero backup describe "$1" --kubecontext "$KUBE_CONTEXT" --details
        '';
      };

      ops.delete = {
        description = "Delete a Velero backup";
        category = "backup";
        options.cluster = {
          type = "enum";
          values = [ config.cluster.name ];
          required = true;
          description = "Target cluster";
        };
        args = [
          {
            name = "name";
            description = "Backup name";
          }
        ];
        package = mkVeleroScript "delete" ''
          velero backup delete "$1" --kubecontext "$KUBE_CONTEXT" --confirm
        '';
      };

      ops.restore = {
        description = "Restore from a Velero backup";
        category = "backup";
        options.cluster = {
          type = "enum";
          values = [ config.cluster.name ];
          required = true;
          description = "Target cluster";
        };
        args = [
          {
            name = "backup";
            description = "Backup name to restore from";
          }
        ];
        package = mkVeleroScript "restore" ''
          velero restore create --from-backup "$1" --kubecontext "$KUBE_CONTEXT" --wait
        '';
      };

      ops.schedules = {
        description = "List Velero backup schedules";
        category = "backup";
        options.cluster = {
          type = "enum";
          values = [ config.cluster.name ];
          required = true;
          description = "Target cluster";
        };
        package = mkVeleroScript "schedules" ''
          velero schedule get --kubecontext "$KUBE_CONTEXT"
        '';
      };

      ops.trigger = {
        description = "Trigger a backup schedule manually";
        category = "backup";
        options.cluster = {
          type = "enum";
          values = [ config.cluster.name ];
          required = true;
          description = "Target cluster";
        };
        args = [
          {
            name = "schedule";
            description = "Schedule name to trigger";
          }
        ];
        package = mkVeleroScript "trigger" ''
          velero backup create --from-schedule "$1" --kubecontext "$KUBE_CONTEXT"
        '';
      };
    })
  ];
}

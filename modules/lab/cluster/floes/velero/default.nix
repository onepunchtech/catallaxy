{
  config,
  lib,
  pkgs,
  cataCharts,
  k8sSpecs,
  k8sHelpers,
  lab,
  ...
}@__floeModuleArgs:

let
  inherit ((import ../../../../../lib/floe { inherit lib; })) mkFloe;
in
(mkFloe {
  name = "velero";
  version = "7.2.1";
  imports = [ ./options.nix ];

  drift = [
    {
      group = "velero.io";
      kinds = [
        "Schedule"
        "BackupStorageLocation"
      ];
      managedBy = [ "velero-server" ];
      reason = ''
        The velero controller defaults spec.skipImmediately on Schedule
        and spec.default on BackupStorageLocation. Neither appears in
        the rendered manifest.
      '';
    }
  ];
  module =
    {
      config,
      lib,
      pkgs,
      cataCharts,
      cfg,
      ...
    }:
    let
      inherit (lib)
        mapAttrs'
        nameValuePair
        optionalAttrs
        optional
        ;

      seaweedCfg =
        config.floes.seaweedfs or {
          enable = false;
          exports = { };
        };

      kubeContext = config.cluster.ref.kubeContext;

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

      bslProvider =
        if cfg.backupStorageLocation.provider == "seaweedfs" then
          "aws"
        else
          cfg.backupStorageLocation.provider;

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

        initContainers =
          optional
            (cfg.backupStorageLocation.provider == "aws" || cfg.backupStorageLocation.provider == "seaweedfs")
            {
              name = "velero-plugin-for-aws";
              image = cfg.images.aws-plugin.ref;
              imagePullPolicy = "IfNotPresent";
              volumeMounts = [
                {
                  mountPath = "/target";
                  name = "plugins";
                }
              ];
            };
      };

      localS3Config = optionalAttrs cfg.local.enable {
        configuration.backupStorageLocation = [
          {
            name = "default";
            provider = "aws";
            bucket = cfg.backupStorageLocation.bucket;
            config = {
              region = cfg.backupStorageLocation.s3.region;
              s3Url = seaweedCfg.exports.s3Endpoint or "http://seaweedfs-s3:8333";
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

            annotations."kapp.k14s.io/update-strategy" = "fallback-on-replace";
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
                    image = cfg.images.aws-cli.ref;
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
                          seaweedCfg.exports.s3Endpoint or "http://seaweedfs-s3:8333"
                        } s3 ls 2>/dev/null; do
                          echo "Waiting for SeaweedFS S3..."
                          sleep 5
                        done
                        aws --endpoint-url ${
                          seaweedCfg.exports.s3Endpoint or "http://seaweedfs-s3:8333"
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
      assertions = [
        {
          assertion = !cfg.local.enable || (seaweedCfg.enable or false);
          message = "Velero local mode requires SeaweedFS to be enabled";
        }
      ];

      floes.velero.network = {

        declared = true;

        # Its bucket-init Job talks to the S3 endpoint, which on these labs
        # is seaweedfs rather than something off-cluster.
        reaches = [ "seaweedfs/s3" ];

        egress.internet.ports = [ 443 ];

      };

      floes.velero.imagesComplete = true;

      floes.velero.images.velero = {

        repository = "velero/velero";

        tag = "v1.16.0";

      };

      bundles.velero-crds.yamls = [ cataCharts.velero.crds ];
      bundles.velero-crds.provides = [ "velero/crds/established" ];

      floes.velero.images = {
        aws-plugin = {
          repository = "velero/velero-plugin-for-aws";
          tag = "v1.11.1";
        };
        aws-cli = {
          repository = "amazon/aws-cli";
          tag = "2.15.44";
        };
      };

      bundles.velero = {
        includeInBootstrap = false;
        helmCharts.velero = {
          chart = cfg.chart;
          releaseName = "velero";
          namespace = cfg.namespace;
          createNamespace = true;
          values = helmValues // localS3Config;
        };
        resources = seaweedResources;
        createNamespaces = [ cfg.namespace ];

        requires = [
          "velero/crds/established"
        ]
        ++ lib.optional cfg.local.enable "seaweedfs/s3/ready";
        provides = [ "velero/backup/ready" ];
        readyProbe = {
          kind = "condition";
          resource = "deployment/velero";
          namespace = cfg.namespace;
          condition = "Available";
          timeout = "5m";
        };
      };

      bundles.velero-schedules = {
        resources = scheduleResources;

        requires = [ "velero/backup/ready" ];
      };

      ops.backup.create = {
        description = "Create a Velero backup";
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

      ops.backup.list = {
        description = "List Velero backups";
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

      ops.backup.describe = {
        description = "Describe a Velero backup";
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

      ops.backup.delete = {
        description = "Delete a Velero backup";
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

      ops.backup.restore = {
        description = "Restore from a Velero backup";
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

      ops.backup.schedules = {
        description = "List Velero backup schedules";
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

      ops.backup.trigger = {
        description = "Trigger a backup schedule manually";
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
    };
})
  __floeModuleArgs

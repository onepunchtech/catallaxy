# modules/cluster/components/loki.nix
#
# Loki log aggregation component — merged high-level options + IR writer.
#
# Provides horizontally-scalable log storage with label-based indexing.

{
  config,
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    optionalAttrs
    ;
  cfg = config.components.loki;

  # Chart reference with fallback
  chartRef = cfg.chart;

  storageConfig =
    if cfg.storage.type == "s3" then
      {
        storage.type = "s3";
        storage.bucketNames = {
          chunks = cfg.storage.s3.bucket;
          ruler = cfg.storage.s3.bucket;
          admin = cfg.storage.s3.bucket;
        };
        storage.s3 = {
          region = cfg.storage.s3.region;
        }
        // optionalAttrs (cfg.storage.s3.endpoint != null) {
          endpoint = cfg.storage.s3.endpoint;
          s3ForcePathStyle = true;
          insecure = true;
        };
      }
    else
      {
        # Filesystem storage - still requires bucketNames for newer chart versions
        storage.type = "filesystem";
        storage.bucketNames = {
          chunks = "chunks";
          ruler = "ruler";
          admin = "admin";
        };
      };
in
{
  # =========================================================================
  # PART 1: High-level options
  # =========================================================================

  options.components.loki = {
    enable = mkEnableOption "Loki log aggregation";

    phase = mkOption {
      type = types.str;
      default = "infrastructure";
      description = "Deployment phase this component belongs to";
    };

    version = mkOption {
      type = types.str;
      default = "6.16.0";
      description = "Loki Helm chart version";
    };

    chart = mkOption {
      type = types.package;
      default = cataCharts.loki.chart;
      description = "Loki Helm chart derivation (default: cataCharts.loki)";
    };

    namespace = mkOption {
      type = types.str;
      default = "loki";
      description = "Namespace for Loki";
    };

    deploymentMode = mkOption {
      type = types.enum [
        "SingleBinary"
        "SimpleScalable"
        "Distributed"
      ];
      default = "SingleBinary";
      description = "Loki deployment topology";
    };

    replicas = mkOption {
      type = types.ints.positive;
      default = 1;
      description = "Replicas (SingleBinary mode) or read/write replicas (SimpleScalable)";
    };

    storage = {
      type = mkOption {
        type = types.enum [
          "filesystem"
          "s3"
        ];
        default = "filesystem";
        description = "Storage backend type";
      };

      s3 = {
        bucket = mkOption {
          type = types.str;
          default = "loki-chunks";
          description = "S3 bucket name";
        };

        endpoint = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            S3 endpoint URL (for S3-compatible storage).
            Use config.components.seaweedfs.ref.s3Endpoint for SeaweedFS.
          '';
        };

        region = mkOption {
          type = types.str;
          default = "us-east-1";
          description = "S3 region";
        };

        secretName = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Secret with S3 credentials (access-key-id, secret-access-key keys)";
        };
      };

      persistence = {
        size = mkOption {
          type = types.str;
          default = "50Gi";
          description = "PVC size for local storage (filesystem mode)";
        };

        storageClass = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Storage class for PVCs";
        };
      };
    };

    retention = mkOption {
      type = types.str;
      default = "744h";
      description = "Log retention period (default 31 days)";
    };

    ref = mkOption {
      type = types.attrs;
      readOnly = true;
      description = "Computed references for Loki";
    };
  };

  # =========================================================================
  # PART 2: Computed refs
  # =========================================================================

  # =========================================================================
  # PART 3: Phase writer
  # =========================================================================

  config = lib.mkMerge [
    {
      components.loki.ref =
        let
          host = "loki.${cfg.namespace}.svc.cluster.local";
        in
        {
          inherit host;
          namespace = cfg.namespace;
          port = 3100;
          url = "http://${host}:3100";
          pushUrl = "http://${host}:3100/loki/api/v1/push";
          queryUrl = "http://${host}:3100";
          # OTLP ingestion endpoint (Loki 3.0+ natively supports OTLP)
          otlpUrl = "http://${host}:3100/otlp";
        };
    }
    (mkIf cfg.enable {
      # Loki helm chart
      phases.${cfg.phase}.bundles.loki = {
        helmCharts.loki = {
          chart = chartRef;
          releaseName = "loki";
          namespace = cfg.namespace;
          createNamespace = true;
          values = {
            deploymentMode = cfg.deploymentMode;

            loki = {
              auth_enabled = false;
              commonConfig.replication_factor = 1;
              limits_config.retention_period = cfg.retention;
              schemaConfig.configs = [
                {
                  from = "2024-01-01";
                  store = "tsdb";
                  object_store = cfg.storage.type;
                  schema = "v13";
                  index = {
                    prefix = "index_";
                    period = "24h";
                  };
                }
              ];
            }
            // storageConfig;

            singleBinary = optionalAttrs (cfg.deploymentMode == "SingleBinary") {
              replicas = cfg.replicas;
              persistence = {
                enabled = true;
                size = cfg.storage.persistence.size;
              }
              // optionalAttrs (cfg.storage.persistence.storageClass != null) {
                storageClassName = cfg.storage.persistence.storageClass;
              };
            };

            # Disable components not used in SingleBinary mode
            read.replicas = if cfg.deploymentMode == "SingleBinary" then 0 else cfg.replicas;
            write.replicas = if cfg.deploymentMode == "SingleBinary" then 0 else cfg.replicas;
            backend.replicas = if cfg.deploymentMode == "SingleBinary" then 0 else cfg.replicas;

            gateway.enabled = false;

            # Disable memcached-exporter sidecars (image tag issues)
            chunksCache.writebackSizeLimit = "500MB";
            resultsCache.writebackSizeLimit = "500MB";
            memcachedExporter.enabled = false;

            # Disable test/monitoring sub-charts
            monitoring.selfMonitoring.enabled = false;
            monitoring.lokiCanary.enabled = false;
            test.enabled = false;
          };
        };

        # Namespace creation
        createNamespaces = [ cfg.namespace ];
      };
    })
  ];
}

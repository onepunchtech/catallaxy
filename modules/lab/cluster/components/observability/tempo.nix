# modules/cluster/components/tempo.nix
#
# Tempo distributed tracing component — merged high-level options + IR writer.
#
# Provides trace storage and querying with native OTLP ingestion.

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
  cfg = config.components.tempo;

  # Chart reference with fallback
  chartRef = cfg.chart;

  # Tempo 2.x uses "trace" (singular) not "traces"
  storageConfig =
    if cfg.storage.type == "s3" then
      {
        trace = {
          backend = "s3";
          s3 = {
            bucket = cfg.storage.s3.bucket;
            region = cfg.storage.s3.region;
          }
          // optionalAttrs (cfg.storage.s3.endpoint != null) {
            endpoint = cfg.storage.s3.endpoint;
            forcepathstyle = true;
            insecure = true;
          };
        };
      }
    else
      {
        trace = {
          backend = "local";
          local.path = "/var/tempo/traces";
        };
      };
in
{
  # =========================================================================
  # PART 1: High-level options
  # =========================================================================

  options.components.tempo = {
    enable = mkEnableOption "Tempo distributed tracing";

    phase = mkOption {
      type = types.str;
      default = "infrastructure";
      description = "Deployment phase this component belongs to";
    };

    version = mkOption {
      type = types.str;
      default = "1.10.3";
      description = "Tempo Helm chart version";
    };

    chart = mkOption {
      type = types.package;
      default = cataCharts.tempo.chart;
      description = "Tempo Helm chart derivation (default: cataCharts.tempo)";
    };

    namespace = mkOption {
      type = types.str;
      default = "tempo";
      description = "Namespace for Tempo";
    };

    deploymentMode = mkOption {
      type = types.enum [
        "monolithic"
        "distributed"
      ];
      default = "monolithic";
      description = "Tempo deployment topology";
    };

    storage = {
      type = mkOption {
        type = types.enum [
          "filesystem"
          "s3"
        ];
        default = "filesystem";
        description = "Trace storage backend";
      };

      s3 = {
        bucket = mkOption {
          type = types.str;
          default = "tempo-traces";
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
          description = "Secret with S3 credentials";
        };
      };

      persistence = {
        size = mkOption {
          type = types.str;
          default = "20Gi";
          description = "PVC size for trace storage (filesystem mode)";
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
      default = "168h";
      description = "Trace retention period (default 7 days)";
    };

    receivers = {
      otlp = {
        grpc = mkOption {
          type = types.bool;
          default = true;
          description = "Enable OTLP gRPC receiver";
        };
        http = mkOption {
          type = types.bool;
          default = true;
          description = "Enable OTLP HTTP receiver";
        };
      };
    };

    ref = mkOption {
      type = types.attrs;
      readOnly = true;
      description = "Computed references for Tempo";
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
      components.tempo.ref =
        let
          host = "tempo.${cfg.namespace}.svc.cluster.local";
        in
        {
          inherit host;
          namespace = cfg.namespace;
          port = 3100;
          url = "http://${host}:3100";
          otlpGrpc = "${host}:4317";
          otlpHttp = "http://${host}:4318";
          queryUrl = "http://${host}:3100";
        };
    }
    (mkIf cfg.enable {
      # Tempo helm chart
      phases.${cfg.phase}.bundles.tempo = {
        helmCharts.tempo = {
          chart = chartRef;
          releaseName = "tempo";
          namespace = cfg.namespace;
          createNamespace = true;
          values = {
            tempo = {
              retention = cfg.retention;

              receivers = {
                otlp = {
                  protocols = {
                    grpc = optionalAttrs cfg.receivers.otlp.grpc { endpoint = "0.0.0.0:4317"; };
                    http = optionalAttrs cfg.receivers.otlp.http { endpoint = "0.0.0.0:4318"; };
                  };
                };
              };

              storage = storageConfig;
            };

            persistence = {
              enabled = cfg.storage.type == "filesystem";
              size = cfg.storage.persistence.size;
            }
            // optionalAttrs (cfg.storage.persistence.storageClass != null) {
              storageClassName = cfg.storage.persistence.storageClass;
            };
          };
        };

        # Namespace creation
        createNamespaces = [ cfg.namespace ];
      };
    })
  ];
}

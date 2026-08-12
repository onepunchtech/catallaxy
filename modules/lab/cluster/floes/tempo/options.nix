{
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption types;
in
{
  options.floes.tempo = {
    chart = mkOption {
      type = types.package;
      default = cataCharts.tempo.chart;
      description = "Tempo Helm chart derivation (default: cataCharts.tempo)";
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
            Use config.floes.seaweedfs.exports.s3Endpoint for SeaweedFS.
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
  };
}

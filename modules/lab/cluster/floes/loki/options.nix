{
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption types;
in
{
  options.floes.loki = {
    chart = mkOption {
      type = types.package;
      default = cataCharts.loki.chart;
      description = "Loki Helm chart derivation (default: cataCharts.loki)";
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
  };
}

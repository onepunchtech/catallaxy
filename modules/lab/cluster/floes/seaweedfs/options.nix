{
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption types;
in
{
  options.floes.seaweedfs = {
    chart = mkOption {
      type = types.package;
      default = cataCharts.seaweedfs.chart;
      description = "Custom chart derivation. When null, uses nixhelm default.";
    };

    master = {
      replicas = mkOption {
        type = types.ints.positive;
        default = 1;
        description = "Number of master server replicas (3 for production)";
      };

      storage = mkOption {
        type = types.str;
        default = "10Gi";
        description = "Storage size for master metadata";
      };
    };

    volume = {
      replicas = mkOption {
        type = types.ints.positive;
        default = 1;
        description = "Number of volume server replicas (3+ for production)";
      };

      storage = mkOption {
        type = types.str;
        default = "50Gi";
        description = "Storage size per volume server";
      };

      storageClass = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "StorageClass for volume server PVCs (null = cluster default)";
      };
    };

    filer = {
      replicas = mkOption {
        type = types.ints.positive;
        default = 1;
        description = "Number of filer replicas (2+ for production)";
      };

      storage = mkOption {
        type = types.str;
        default = "10Gi";
        description = "Storage size for filer metadata";
      };

      s3 = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Enable S3 API gateway on the filer";
        };
      };
    };

    s3 = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable S3 API";
      };

      port = mkOption {
        type = types.port;
        default = 8333;
        description = "S3 API port";
      };
    };
  };
}

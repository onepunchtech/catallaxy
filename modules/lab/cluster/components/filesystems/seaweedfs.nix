# modules/cluster/components/seaweedfs.nix
#
# SeaweedFS distributed storage component — merged high-level options + IR writer.
#
# Provides S3-compatible object storage.

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
  cfg = config.components.seaweedfs;

  # Chart reference with fallback
  chartRef = cfg.chart;
in
{
  # =========================================================================
  # PART 1: High-level options
  # =========================================================================

  options.components.seaweedfs = {
    enable = mkEnableOption "SeaweedFS distributed storage";

    phase = mkOption {
      type = types.str;
      default = "infrastructure";
      description = "Deployment phase this component belongs to";
    };

    version = mkOption {
      type = types.str;
      default = "3.71";
      description = "SeaweedFS version";
    };

    namespace = mkOption {
      type = types.str;
      default = "seaweedfs";
      description = "Namespace for SeaweedFS";
    };

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

    ref = mkOption {
      type = types.attrs;
      readOnly = true;
      description = "Computed references for SeaweedFS";
    };
  };

  # =========================================================================
  # PART 2: Computed refs and config
  # =========================================================================

  config = lib.mkMerge [
    {
      components.seaweedfs.ref = {
        namespace = cfg.namespace;
        s3Endpoint = "http://seaweedfs-s3.${cfg.namespace}.svc.cluster.local:${toString cfg.s3.port}";
        filerEndpoint = "http://seaweedfs-filer.${cfg.namespace}.svc.cluster.local:8888";
      };
    }

    # =========================================================================
    # PART 3: Phase writer
    # =========================================================================

    (mkIf cfg.enable {
      phases.${cfg.phase}.bundles.seaweedfs = {
        # SeaweedFS helm chart
        helmCharts.seaweedfs = {
          chart = chartRef;
          releaseName = "seaweedfs";
          namespace = cfg.namespace;
          createNamespace = true;
          values = {
            master = {
              replicas = cfg.master.replicas;
              storage = cfg.master.storage;
            };

            volume = {
              replicas = cfg.volume.replicas;
              storage = cfg.volume.storage;
            }
            // optionalAttrs (cfg.volume.storageClass != null) {
              storageClass = cfg.volume.storageClass;
            };

            filer = {
              replicas = cfg.filer.replicas;
              storage = cfg.filer.storage;
              s3.enabled = cfg.filer.s3.enable;
            };

            s3 = {
              enabled = cfg.s3.enable;
              port = cfg.s3.port;
            };
          };
        };

        # Namespace creation
        createNamespaces = [ cfg.namespace ];
      };
    })
  ];
}

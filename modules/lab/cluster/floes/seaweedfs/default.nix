{
  config,
  lib,
  pkgs,
  cataCharts,
  k8sSpecs,
  k8sHelpers,
  lab,
  ...
}:

let
  inherit ((import ../../../../../lib/floe { inherit lib; })) floeOptions;
  cfg = config.floes.seaweedfs;
in
{
  imports = [
    (floeOptions {
      name = "seaweedfs";
      version = "3.71";
    })
    ./options.nix
  ];

  options.floes.seaweedfs.exports = {
    namespace = lib.mkOption {
      type = lib.types.str;
      default = "seaweedfs";
      description = "Namespace SeaweedFS runs in.";
    };
    s3Endpoint = lib.mkOption {
      type = lib.types.str;
      default = "http://seaweedfs-s3.seaweedfs.svc.cluster.local:8333";
      description = "S3 API endpoint (http URL) for buckets and objects.";
    };
    filerEndpoint = lib.mkOption {
      type = lib.types.str;
      default = "http://seaweedfs-filer.seaweedfs.svc.cluster.local:8888";
      description = "Filer HTTP endpoint (for direct file operations).";
    };
  };

  config = lib.mkIf cfg.enable (
    let
      inherit (lib) optionalAttrs;

      versionedImage = cfg.images.seaweedfs.ref;
    in
    {
      floes.seaweedfs.images.seaweedfs = {
        repository = "chrislusf/seaweedfs";
        tag = cfg.version;
      };

      floes.seaweedfs.exports = {
        inherit (cfg) namespace;
        s3Endpoint = "http://seaweedfs-s3.${cfg.namespace}.svc.cluster.local:${toString cfg.s3.port}";
        filerEndpoint = "http://seaweedfs-filer.${cfg.namespace}.svc.cluster.local:8888";
      };

      floes.seaweedfs.network = {

        declared = true;

        serves.s3.port = 8333;

        serves.filer.port = 8888;

        serves.master.port = 9333;

      };

      floes.seaweedfs.imagesComplete = true;

      floes.seaweedfs.bundles.seaweedfs = {
        helmCharts.seaweedfs = {
          chart = cfg.chart;
          releaseName = "seaweedfs";
          namespace = cfg.namespace;
          createNamespace = true;
          values = {

            master = {
              replicas = cfg.master.replicas;
              storage = cfg.master.storage;
              imageOverride = versionedImage;
              nodeSelector = { };
            };

            volume = {
              replicas = cfg.volume.replicas;
              storage = cfg.volume.storage;
              imageOverride = versionedImage;
              nodeSelector = { };
            }
            // optionalAttrs (cfg.volume.storageClass != null) {
              storageClass = cfg.volume.storageClass;
            };

            filer = {
              replicas = cfg.filer.replicas;
              storage = cfg.filer.storage;
              s3.enabled = cfg.filer.s3.enable;
              imageOverride = versionedImage;
              nodeSelector = { };
            };

            s3 = {
              enabled = cfg.s3.enable;
              port = cfg.s3.port;
              imageOverride = versionedImage;
              nodeSelector = { };
            };
          };
        };

        resources.seaweedfs-db-init-config = {
          apiVersion = "v1";
          kind = "ConfigMap";
          metadata = {
            name = "seaweedfs-db-init-config";
            namespace = cfg.namespace;
          };
        };

        createNamespaces = [ cfg.namespace ];

        provides = [ "seaweedfs/s3/ready" ];

        readyProbe = {
          kind = "condition";
          resource =
            if cfg.s3.enable then
              "deployment/seaweedfs-s3"
            else if cfg.filer.s3.enable then
              "statefulset/seaweedfs-filer"
            else
              "statefulset/seaweedfs-master";
          namespace = cfg.namespace;

          condition = "Available";
          timeout = "10m";
        };
      };
    }
  );
}

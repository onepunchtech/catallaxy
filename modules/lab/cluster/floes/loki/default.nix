{
  config,
  lib,
  pkgs,
  cataCharts,
  k8sSpecs,
  k8sHelpers,
  ...
}@__floeModuleArgs:

let
  inherit ((import ../../../../../lib/floe { inherit lib; })) mkFloe refs;
in
(mkFloe {
  name = "loki";
  version = "6.16.0";
  imports = [ ./options.nix ];

  exports =
    { lib, ... }:
    {
      logIngest = lib.mkOption {
        type = refs.mkCapability {
          ready = refs.tokenOption ''"Loki is accepting writes and serving queries."'';
        };
        default = null;
        description = ''
          Log ingestion, or null when this floe is off. Consumers that
          export logs here assert on this rather than on
          `floes.loki.enable`.
        '';
      };
      host = lib.mkOption {
        type = lib.types.str;
        default = "loki.loki.svc.cluster.local";
        description = "In-cluster Loki service DNS name.";
      };
      namespace = lib.mkOption {
        type = lib.types.str;
        default = "loki";
        description = "Namespace Loki runs in.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 3100;
        description = "Loki HTTP API port.";
      };
      url = lib.mkOption {
        type = lib.types.str;
        default = "http://loki.loki.svc.cluster.local:3100";
        description = "Loki base URL (http://host:port).";
      };
      pushUrl = lib.mkOption {
        type = lib.types.str;
        default = "http://loki.loki.svc.cluster.local:3100/loki/api/v1/push";
        description = "Loki push endpoint (loki/api/v1/push).";
      };
      queryUrl = lib.mkOption {
        type = lib.types.str;
        default = "http://loki.loki.svc.cluster.local:3100";
        description = "Loki query endpoint.";
      };
      otlpUrl = lib.mkOption {
        type = lib.types.str;
        default = "http://loki.loki.svc.cluster.local:3100/otlp";
        description = "Loki OTLP ingestion endpoint (Loki 3.0+).";
      };
    };
  module =
    { cfg, ... }:
    let
      inherit (lib) optionalAttrs;

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

            storage.type = "filesystem";
            storage.bucketNames = {
              chunks = "chunks";
              ruler = "ruler";
              admin = "admin";
            };
          };

      host = "loki.${cfg.namespace}.svc.cluster.local";
    in
    {
      floes.loki.exports = {
        logIngest.ready = "loki/read/ready";
        inherit host;
        inherit (cfg) namespace;
        port = 3100;
        url = "http://${host}:3100";
        pushUrl = "http://${host}:3100/loki/api/v1/push";
        queryUrl = "http://${host}:3100";

        otlpUrl = "http://${host}:3100/otlp";
      };

      bundles.loki = {
        helmCharts.loki = {
          chart = cfg.chart;
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

            read.replicas = if cfg.deploymentMode == "SingleBinary" then 0 else cfg.replicas;
            write.replicas = if cfg.deploymentMode == "SingleBinary" then 0 else cfg.replicas;
            backend.replicas = if cfg.deploymentMode == "SingleBinary" then 0 else cfg.replicas;

            gateway.enabled = false;

            chunksCache.enabled = false;
            resultsCache.enabled = false;
            memcachedExporter.enabled = false;

            monitoring.selfMonitoring.enabled = false;
            monitoring.lokiCanary.enabled = false;
            test.enabled = false;
          };
        };

        createNamespaces = [ cfg.namespace ];

        provides = [ "loki/read/ready" ];
        readyProbe = {
          kind = "condition";
          resource = "statefulset/loki";
          namespace = cfg.namespace;
          condition = "Available";
          timeout = "10m";
        };
      };
    };
})
  __floeModuleArgs

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
  inherit ((import ../../../../../lib/floe { inherit lib; })) mkFloe refs;
in
(mkFloe {
  name = "tempo";
  version = "1.10.3";
  imports = [ ./options.nix ];

  exports =
    { lib, ... }:
    {
      traceIngest = lib.mkOption {
        type = refs.mkCapability {
          ready = refs.tokenOption ''"Tempo is accepting spans and serving queries."'';
        };
        default = null;
        description = ''
          Trace ingestion, or null when this floe is off. Consumers that
          export spans or query traces gate on this.
        '';
      };
      host = lib.mkOption {
        type = lib.types.str;
        default = "tempo.tempo.svc.cluster.local";
        description = "In-cluster Tempo service DNS name.";
      };
      namespace = lib.mkOption {
        type = lib.types.str;
        default = "tempo";
        description = "Namespace Tempo runs in.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 3100;
        description = "Tempo HTTP API port.";
      };
      url = lib.mkOption {
        type = lib.types.str;
        default = "http://tempo.tempo.svc.cluster.local:3100";
        description = "Tempo base URL (http://host:port).";
      };
      queryUrl = lib.mkOption {
        type = lib.types.str;
        default = "http://tempo.tempo.svc.cluster.local:3100";
        description = "Tempo query endpoint (grafana datasource URL).";
      };
      otlpGrpc = lib.mkOption {
        type = lib.types.str;
        default = "tempo.tempo.svc.cluster.local:4317";
        description = "OTLP gRPC ingestion endpoint (host:4317).";
      };
      otlpHttp = lib.mkOption {
        type = lib.types.str;
        default = "http://tempo.tempo.svc.cluster.local:4318";
        description = "OTLP HTTP ingestion endpoint (http://host:4318).";
      };
    };
  module =
    { cfg, ... }:
    let
      inherit (lib) optionalAttrs;

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

      host = "tempo.${cfg.namespace}.svc.cluster.local";
    in
    {
      floes.tempo.exports = {
        traceIngest.ready = "tempo/write/ready";
        inherit host;
        inherit (cfg) namespace;
        port = 3100;
        url = "http://${host}:3100";
        queryUrl = "http://${host}:3100";
        otlpGrpc = "${host}:4317";
        otlpHttp = "http://${host}:4318";
      };

      floes.tempo.network = {

        declared = true;

        serves.api.port = 3100;

        serves.otlp.port = 4317;

      };

      floes.tempo.imagesComplete = true;

      floes.tempo.images.tempo = {

        repository = "grafana/tempo";

        tag = "2.7.1";

      };

      bundles.tempo = {
        helmCharts.tempo = {
          chart = cfg.chart;
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

        createNamespaces = [ cfg.namespace ];

        provides = [ "tempo/write/ready" ];
        readyProbe = {
          kind = "condition";
          resource = "statefulset/tempo";
          namespace = cfg.namespace;
          condition = "Available";
          timeout = "10m";
        };
      };
    };
})
  __floeModuleArgs

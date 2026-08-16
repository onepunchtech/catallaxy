{
  lab,
  config,
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption mkEnableOption types;
  inherit (import ../../../../../lib/floe { inherit lib; }) refs;
in
{
  options.floes.otel-collector = {
    chart = mkOption {
      type = types.package;
      default = cataCharts.otel-collector.chart;
      description = "OpenTelemetry Collector Helm chart derivation";
    };

    agent = {
      enable = mkEnableOption "OTEL agent (DaemonSet for log collection)";

      namespaces = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Namespaces to collect logs from (empty = all namespaces)";
      };

      excludeNamespaces = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Namespaces to exclude from log collection (otel namespace auto-excluded)";
      };

      gateway.endpoint = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Gateway OTLP endpoint (defaults to local gateway if not set)";
      };

      resources = {
        requests = {
          cpu = mkOption {
            type = types.str;
            default = "50m";
            description = "CPU each agent is guaranteed. Agents run on every node, so this is multiplied by node count.";
          };
          memory = mkOption {
            type = types.str;
            default = "128Mi";
            description = "Memory each agent is guaranteed.";
          };
        };
        limits = {
          cpu = mkOption {
            type = types.str;
            default = "200m";
            description = "CPU ceiling for an agent.";
          };
          memory = mkOption {
            type = types.str;
            default = "256Mi";
            description = "Memory ceiling for an agent.";
          };
        };
      };
    };

    gateway = {
      enable = mkEnableOption "OTEL gateway (Deployment for receiving/forwarding)";

      replicas = mkOption {
        type = types.ints.positive;
        default = 1;
        description = "How many gateway replicas to run.";
      };

      external = {
        enable = mkEnableOption "Expose gateway externally";
        domain = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Hostname the gateway accepts OTLP on from outside the cluster. Null keeps it internal.";
        };
        tls = {
          issuerRef = mkOption {
            type = types.nullOr (
              types.submodule {
                options = {
                  name = mkOption {
                    type = types.str;
                    description = "Name of the issuer.";
                  };
                  kind = mkOption {
                    type = types.str;
                    default = "ClusterIssuer";
                    description = "Issuer scope. `ClusterIssuer` is lab-wide; `Issuer` is confined to the namespace.";
                  };
                };
              }
            );
            default = null;
            description = "Issuer that signs the gateway's serving certificate. Null mints none.";
          };
          secretName = mkOption {
            type = types.str;
            default = "otel-gateway-tls";
            description = "Secret the issued certificate lands in.";
          };
        };
        tier = mkOption {
          type = types.enum [
            "public"
            "internal"
          ];

          default = lab.policy.exposure.defaultTier or "public";
          description = "Lab network tier to attach to. `internal` keeps the endpoint off the public gateway.";
        };
      };

      resources = {
        requests = {
          cpu = mkOption {
            type = types.str;
            default = "100m";
            description = "CPU the gateway is guaranteed.";
          };
          memory = mkOption {
            type = types.str;
            default = "256Mi";
            description = "Memory the gateway is guaranteed.";
          };
        };
        limits = {
          cpu = mkOption {
            type = types.str;
            default = "500m";
            description = "CPU ceiling for the gateway.";
          };
          memory = mkOption {
            type = types.str;
            default = "512Mi";
            description = "Memory ceiling. Batching and retry buffers are what push this.";
          };
        };
      };
    };

    exporters = {
      otlp.endpoint = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Where the gateway forwards traces and metrics over OTLP gRPC. Null forwards nowhere.";
      };
      otlphttp.endpoint = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Same, over OTLP HTTP.";
      };
      prometheus = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Forward logs to Loki.";
        };
        endpoint = mkOption {
          type = types.str;
          default = "";
          description = "Loki push endpoint.";
        };
      };
      loki = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Expose metrics for Prometheus to scrape.";
        };
        endpoint = mkOption {
          type = types.str;
          default = "";
          description = "Endpoint Prometheus scrapes.";
        };
      };
    };

    ports = {
      otlpGrpc = mkOption {
        type = types.port;
        default = 4317;
        description = "Port the collector accepts OTLP gRPC on.";
      };
      otlpHttp = mkOption {
        type = types.port;
        default = 4318;
        description = "Port it accepts OTLP HTTP on.";
      };
      prometheus = mkOption {
        type = types.port;
        default = 8889;
        description = "Port it serves its own Prometheus metrics on.";
      };
    };

    tls = {

      caBundle = mkOption {
        type = refs.nullableMountableRef;
        default = config.floes.cert-manager.exports.caBundle;
        description = ''
          CA bundle to mount into the collector for TLS verification of
          its exporters. Defaults to whatever cert-manager publishes.
        '';
      };
    };
  };
}

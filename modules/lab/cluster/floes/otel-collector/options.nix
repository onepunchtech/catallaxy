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
          };
          memory = mkOption {
            type = types.str;
            default = "128Mi";
          };
        };
        limits = {
          cpu = mkOption {
            type = types.str;
            default = "200m";
          };
          memory = mkOption {
            type = types.str;
            default = "256Mi";
          };
        };
      };
    };

    gateway = {
      enable = mkEnableOption "OTEL gateway (Deployment for receiving/forwarding)";

      replicas = mkOption {
        type = types.ints.positive;
        default = 1;
      };

      external = {
        enable = mkEnableOption "Expose gateway externally";
        domain = mkOption {
          type = types.nullOr types.str;
          default = null;
        };
        tls = {
          issuerRef = mkOption {
            type = types.nullOr (
              types.submodule {
                options = {
                  name = mkOption { type = types.str; };
                  kind = mkOption {
                    type = types.str;
                    default = "ClusterIssuer";
                  };
                };
              }
            );
            default = null;
          };
          secretName = mkOption {
            type = types.str;
            default = "otel-gateway-tls";
          };
        };
        tier = mkOption {
          type = types.enum [
            "public"
            "internal"
          ];

          default = lab.policy.exposure.defaultTier or "public";
        };
      };

      resources = {
        requests = {
          cpu = mkOption {
            type = types.str;
            default = "100m";
          };
          memory = mkOption {
            type = types.str;
            default = "256Mi";
          };
        };
        limits = {
          cpu = mkOption {
            type = types.str;
            default = "500m";
          };
          memory = mkOption {
            type = types.str;
            default = "512Mi";
          };
        };
      };
    };

    exporters = {
      otlp.endpoint = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      otlphttp.endpoint = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      prometheus = {
        enable = mkOption {
          type = types.bool;
          default = false;
        };
        endpoint = mkOption {
          type = types.str;
          default = "";
        };
      };
      loki = {
        enable = mkOption {
          type = types.bool;
          default = false;
        };
        endpoint = mkOption {
          type = types.str;
          default = "";
        };
      };
    };

    ports = {
      otlpGrpc = mkOption {
        type = types.port;
        default = 4317;
      };
      otlpHttp = mkOption {
        type = types.port;
        default = 4318;
      };
      prometheus = mkOption {
        type = types.port;
        default = 8889;
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

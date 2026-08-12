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
  contracts = import ../../../../../lib/contracts { inherit lib; };
in
{
  options.floes.grafana = {
    chart = mkOption {
      type = types.package;
      default = cataCharts.grafana.chart;
      description = "Grafana Helm chart derivation (default: cataCharts.grafana)";
    };

    domain = mkOption {
      type = types.str;
      default = "grafana.local";
      description = "Domain for Grafana external access";
    };

    adminCredentialsSecret = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Existing secret with admin-user and admin-password keys";
    };

    persistence = {
      enable = mkOption {
        type = types.bool;
        default = true;
      };
      size = mkOption {
        type = types.str;
        default = "10Gi";
      };
      storageClass = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
    };

    datasources = {
      prometheus.url = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Prometheus URL. Auto-configured from floes.prometheus.exports when null.";
      };
      loki.url = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Loki URL. Auto-configured from floes.loki.exports when null.";
      };
      tempo.url = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Tempo URL. Auto-configured from floes.tempo.exports when null.";
      };
    };

    plugins = mkOption {
      type = types.listOf types.str;
      default = [ ];
    };

    sidecar.dashboards = {
      enable = mkOption {
        type = types.bool;
        default = true;
      };
      searchNamespace = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
    };

    oidc = {
      enable = mkEnableOption "OIDC authentication via Kanidm";
      issuerUrl = mkOption {
        type = types.str;
        default = "";
      };
      clientId = mkOption {
        type = types.str;
        default = "grafana";
      };
      client = mkOption {
        type = contracts.oidc.nullableClient;
        default = config.floes.kanidm.exports.oauth2Clients.${config.floes.grafana.oidc.clientId} or null;
        defaultText = lib.literalExpression "config.floes.kanidm.exports.oauth2Clients.\${oidc.clientId}";
        description = ''
          The identity provider's published record for this client, or
          null when nothing in the lab publishes one.

          Defaults to kanidm's. Assign any floe's equivalent export to
          run against a different provider; the default names kanidm but
          the type does not. Null is also how you opt out.
        '';
      };
      clientSecretRef = mkOption {
        type = types.nullOr (
          types.submodule {
            options = {
              name = mkOption { type = types.str; };
              key = mkOption {
                type = types.str;
                default = "client-secret";
              };
            };
          }
        );
        default = null;
      };
      scopes = mkOption {
        type = types.listOf types.str;
        default = [
          "openid"
          "email"
          "profile"
          "groups"
        ];
      };
      roleAttributePath = mkOption {
        type = types.str;
        default = "contains(groups[*], 'grafana-admins') && 'Admin' || contains(groups[*], 'grafana-editors') && 'Editor' || 'Viewer'";
      };
      allowSignUp = mkOption {
        type = types.bool;
        default = true;
      };
      autoLogin = mkOption {
        type = types.bool;
        default = false;
      };
      name = mkOption {
        type = types.str;
        default = "Kanidm";
      };
      tlsSkipVerify = mkOption {
        type = types.bool;
        default = false;
      };
      tlsCaCertSecretRef = mkOption {
        type = types.nullOr (
          types.submodule {
            options = {
              name = mkOption { type = types.str; };
              key = mkOption {
                type = types.str;
                default = "ca.crt";
              };
            };
          }
        );
        default = null;
      };
      tlsCaBundle = mkOption {
        type = refs.nullableMountableRef;
        default = config.floes.cert-manager.exports.caBundle;
        description = ''
          CA bundle mounted so grafana trusts the OIDC issuer's TLS
          cert. Defaults to whatever cert-manager publishes: null when
          nothing produces one, which is also how you opt out.
        '';
      };
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

        default = config.floes.cert-manager.exports.defaultIssuerRef or null;
      };
      secretName = mkOption {
        type = types.str;
        default = "grafana-tls";
      };
    };

    replicas = mkOption {
      type = types.ints.positive;
      default = 1;
    };

    gateway = {
      enable = mkOption {
        type = types.bool;
        default = true;
      };
      gatewayRef = mkOption {
        type = types.str;
        default = "default-gateway";
      };
      gatewayNamespace = mkOption {
        type = types.nullOr types.str;
        default = "kube-system";
      };
      tier = mkOption {
        type = types.enum [
          "public"
          "internal"
        ];

        default = lab.policy.exposure.defaultTier or "public";
      };
    };
  };
}

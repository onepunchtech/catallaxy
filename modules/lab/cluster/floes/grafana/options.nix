{
  lab,
  config,
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption mkEnableOption types;
  inherit (import ../../../../../lib/floe { inherit lib; }) gatewayOptions refs;
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
        description = "Claim a volume for Grafana's own database. Off keeps dashboards and users only as long as the pod lives.";
      };
      size = mkOption {
        type = types.str;
        default = "10Gi";
        description = "Size of that volume.";
      };
      storageClass = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "StorageClass for it. Null takes the cluster default.";
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
      description = "Grafana plugins to install at startup, by plugin id.";
    };

    sidecar.dashboards = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Watch for dashboard ConfigMaps and load them, so a floe can ship its own dashboards.";
      };
      searchNamespace = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Namespace to watch for those. Null watches every namespace.";
      };
    };

    oidc = {
      enable = mkEnableOption "OIDC authentication via Kanidm";
      issuerUrl = mkOption {
        type = types.str;
        default = "";
        description = "OIDC issuer URL. Usually read from the identity floe's exports rather than written out.";
      };
      clientId = mkOption {
        type = types.str;
        default = "grafana";
        description = "Client ID Grafana presents to the issuer.";
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
              name = mkOption {
                type = types.str;
                description = "Name of that Secret.";
              };
              key = mkOption {
                type = types.str;
                default = "client-secret";
                description = "Key within it.";
              };
            };
          }
        );
        default = null;
        description = "Secret holding the OIDC client secret.";
      };
      scopes = mkOption {
        type = types.listOf types.str;
        default = [
          "openid"
          "email"
          "profile"
          "groups"
        ];
        description = "Scopes requested at login. `groups` is what `roleAttributePath` reads.";
      };
      roleAttributePath = mkOption {
        type = types.str;
        default = "contains(groups[*], 'grafana-admins') && 'Admin' || contains(groups[*], 'grafana-editors') && 'Editor' || 'Viewer'";
        description = "JMESPath over the token that decides a user's Grafana role. The default grants Admin to one group and Viewer to everyone else.";
      };
      allowSignUp = mkOption {
        type = types.bool;
        default = true;
        description = "Create a Grafana user on first login. Off means the account has to exist already.";
      };
      autoLogin = mkOption {
        type = types.bool;
        default = false;
        description = "Skip Grafana's login page and go straight to the issuer.";
      };
      name = mkOption {
        type = types.str;
        default = "Kanidm";
        description = "Label for the login button.";
      };
      tlsSkipVerify = mkOption {
        type = types.bool;
        default = false;
        description = "Skip TLS verification when talking to the issuer. Prefer trusting the lab CA over turning this on.";
      };
      tlsCaCertSecretRef = mkOption {
        type = types.nullOr (
          types.submodule {
            options = {
              name = mkOption {
                type = types.str;
                description = "Name of that Secret.";
              };
              key = mkOption {
                type = types.str;
                default = "ca.crt";
                description = "Key within it.";
              };
            };
          }
        );
        default = null;
        description = "Secret holding a CA bundle to trust when talking to the issuer.";
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

        default = config.floes.cert-manager.exports.defaultIssuerRef or null;
        description = "Issuer that signs the serving certificate. Null mints none.";
      };
      secretName = mkOption {
        type = types.str;
        default = "grafana-tls";
        description = "Secret the issued certificate lands in.";
      };
    };

    replicas = mkOption {
      type = types.ints.positive;
      default = 1;
      description = "How many Grafana replicas to run. Above one needs shared storage or an external database.";
    };

    gateway = gatewayOptions {
      inherit lab;
    };
  };
}

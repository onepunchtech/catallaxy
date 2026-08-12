{
  lib,
  config,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption mkEnableOption types;
  contracts = import ../../../../../lib/contracts { inherit lib; };
  inherit (import ../../../../../lib/floe { inherit lib; }) refs;
in
{
  options.floes.zot = {
    chart = mkOption {
      type = types.package;
      default = cataCharts.zot.chart;
    };
    domain = mkOption {
      type = types.str;
      default = "";
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
        default = "zot-tls";
      };
      caBundle = mkOption {
        type = refs.nullableMountableRef;
        default = config.floes.cert-manager.exports.caBundle;
        description = ''
          Lab CA bundle to mount into the zot pod so the OIDC RP can
          validate the kanidm issuer's TLS cert when it is signed by the
          lab CA. Defaults to whatever cert-manager publishes: null
          when nothing produces one, which is also how you opt out.
        '';
      };
    };

    storage = {
      rootDirectory = mkOption {
        type = types.str;
        default = "/var/lib/zot";
      };
      size = mkOption {
        type = types.str;
        default = "50Gi";
      };
      storageClass = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      dedupe = mkOption {
        type = types.bool;
        default = true;
      };
    };

    auth = {
      enable = mkOption {
        type = types.bool;
        default = false;
      };
      htpasswdSecret = mkOption {
        type = types.str;
        default = "zot-htpasswd";
      };
    };

    oidc = {
      enable = mkEnableOption "OIDC authentication via Kanidm";
      providerName = mkOption {
        type = types.str;
        default = "OIDC";
        description = ''
          Human-friendly provider name shown in zot's web UI on the
          "Sign in with …" button. Underlying provider key remains the
          generic `oidc` (zot only accepts a fixed set of provider keys).
        '';
      };
      issuerUrl = mkOption {
        type = types.str;
        default = "";
      };
      clientId = mkOption {
        type = types.str;
        default = "zot";
      };
      client = mkOption {
        type = contracts.oidc.nullableClient;
        default = config.floes.kanidm.exports.oauth2Clients.${config.floes.zot.oidc.clientId} or null;
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
          "groups"
        ];
      };
      usernameClaim = mkOption {
        type = types.str;
        default = "preferred_username";
      };
      groupsClaim = mkOption {
        type = types.str;
        default = "groups";
      };
      adminGroups = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
      readOnlyGroups = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
    };

    search = {
      enable = mkOption {
        type = types.bool;
        default = true;
      };
    };
    ui = {
      enable = mkOption {
        type = types.bool;
        default = true;
      };
    };
    http = {
      port = mkOption {
        type = types.port;
        default = 5000;
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
    };
  };
}

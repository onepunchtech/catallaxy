{
  lab,
  config,
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption mkEnableOption types;
  contracts = import ../../../../../lib/contracts { inherit lib; };
in
{
  options.floes.forgejo = {
    chart = mkOption {
      type = types.package;
      default = cataCharts.forgejo.chart;
      description = "Custom chart derivation";
    };

    domain = mkOption {
      type = types.str;
      description = "Domain for Forgejo external access";
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
        default = "forgejo-tls";
      };
    };

    database = {
      host = mkOption { type = types.str; };
      port = mkOption {
        type = types.port;
        default = 5432;
      };
      name = mkOption {
        type = types.str;
        default = "forgejo";
      };
      user = mkOption {
        type = types.str;
        default = "forgejo";
      };
      secretRef = mkOption {
        type = types.submodule {
          options = {
            name = mkOption { type = types.str; };
            key = mkOption {
              type = types.str;
              default = "password";
            };
          };
        };
      };
      ssl = mkOption {
        type = types.bool;
        default = false;
      };
    };

    oidc = {
      enable = mkEnableOption "OIDC authentication via Kanidm";
      clientId = mkOption {
        type = types.str;
        default = "forgejo";
      };
      client = mkOption {
        type = contracts.oidc.nullableClient;
        default = config.floes.kanidm.exports.oauth2Clients.${config.floes.forgejo.oidc.clientId} or null;
        defaultText = lib.literalExpression "config.floes.kanidm.exports.oauth2Clients.\${oidc.clientId}";
        description = ''
          The identity provider's published record for this client, or
          null when nothing in the lab publishes one.

          Defaults to kanidm's. Assign any floe's equivalent export to
          run against a different provider; the default names kanidm but
          the type does not. Null is also how you opt out.
        '';
      };
      issuerUrl = mkOption {
        type = types.str;
        default = "";
      };
      clientSecretRef = mkOption {
        type = types.nullOr (
          types.submodule {
            options = {
              name = mkOption { type = types.str; };
              namespace = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = ''
                  Namespace containing the OIDC client Secret. Null =
                  forgejo's own namespace. Set explicitly when the
                  Secret lives cross-namespace (e.g. kaniop reconciles
                  the KanidmOAuth2Client CR without a namespace attr,
                  so the Secret lands in the kanidm namespace).
                '';
              };
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
      autoDiscoverUrl = mkOption {
        type = types.str;
        default = "";
      };
      providerName = mkOption {
        type = types.str;
        default = "Kanidm";
      };
      usernameClaim = mkOption {
        type = types.str;
        default = "preferred_username";
      };
      groupsClaim = mkOption {
        type = types.str;
        default = "groups";
      };
      adminGroup = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
    };

    storage = {
      size = mkOption {
        type = types.str;
        default = "10Gi";
      };
      storageClass = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
    };

    server = {
      sshPort = mkOption {
        type = types.port;
        default = 22;
      };
      httpPort = mkOption {
        type = types.port;
        default = 3000;
      };
      lfsEnabled = mkOption {
        type = types.bool;
        default = true;
      };
    };

    admin = {
      existingSecret = mkOption {
        type = types.nullOr types.str;
        default = null;
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
        description = "Lab network tier (public | internal).";
      };
    };
  };
}

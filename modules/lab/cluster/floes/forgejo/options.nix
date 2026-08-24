{
  lab,
  config,
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption mkEnableOption types;
  inherit (import ../../../../../lib/floe { inherit lib; }) gatewayOptions;
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
      issuerRef = contracts.tls.issuerRefOption {
        default = contracts.tls.defaultIssuer config;
        description = "Issuer that signs the serving certificate. Null mints none.";
      };

      secretName = mkOption {
        type = types.str;
        default = "forgejo-tls";
        description = "Secret the issued certificate lands in.";
      };
    };

    database = {
      host = mkOption {
        type = types.str;
        description = "Hostname of the Postgres server.";
      };
      port = mkOption {
        type = types.port;
        default = 5432;
        description = "Port it listens on.";
      };
      name = mkOption {
        type = types.str;
        default = "forgejo";
        description = "Database name.";
      };
      user = mkOption {
        type = types.str;
        default = "forgejo";
        description = "Role Forgejo connects as.";
      };
      secretRef = mkOption {
        type = types.submodule {
          options = {
            name = mkOption {
              type = types.str;
              description = "Name of that Secret.";
            };
            key = mkOption {
              type = types.str;
              default = "password";
              description = "Key within it.";
            };
          };
        };
        description = "Secret holding that role's password.";
      };
      ssl = mkOption {
        type = types.bool;
        default = false;
        description = "Require TLS on the database connection.";
      };
    };

    oidc = {
      enable = mkEnableOption "OIDC authentication via Kanidm";
      clientId = mkOption {
        type = types.str;
        default = "forgejo";
        description = "Client ID Forgejo presents to the issuer.";
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
        description = "OIDC issuer URL. Usually read from the identity floe's exports rather than written out.";
      };
      clientSecretRef = mkOption {
        type = types.nullOr (
          types.submodule {
            options = {
              name = mkOption {
                type = types.str;
                description = "Name of the Secret holding the client secret.";
              };
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
                description = "Key within that Secret.";
              };
            };
          }
        );
        default = null;
        description = "Secret holding the OIDC client secret. Null means the bootstrap mints one.";
      };
      scopes = mkOption {
        type = types.listOf types.str;
        default = [
          "openid"
          "email"
          "profile"
          "groups"
        ];
        description = "Scopes requested at login. `groups` is what `adminGroup` reads.";
      };
      autoDiscoverUrl = mkOption {
        type = types.str;
        default = "";
        description = "Discovery document URL, when it is not the issuer's well-known path.";
      };
      providerName = mkOption {
        type = types.str;
        default = "Kanidm";
        description = "Label for the login button.";
      };
      usernameClaim = mkOption {
        type = types.str;
        default = "preferred_username";
        description = "Claim to read the username from.";
      };
      groupsClaim = mkOption {
        type = types.str;
        default = "groups";
        description = "Claim to read group membership from.";
      };
      adminGroup = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Group whose members administer Forgejo. Null grants nobody admin through OIDC.";
      };
    };

    storage = {
      size = mkOption {
        type = types.str;
        default = "10Gi";
        description = "Size of the volume holding repositories.";
      };
      storageClass = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "StorageClass for it. Null takes the cluster default.";
      };
    };

    server = {
      sshPort = mkOption {
        type = types.port;
        default = 22;
        description = "Port Forgejo serves SSH git traffic on.";
      };
      httpPort = mkOption {
        type = types.port;
        default = 3000;
        description = "Port it serves HTTP on.";
      };
      lfsEnabled = mkOption {
        type = types.bool;
        default = true;
        description = "Store large files through git-lfs.";
      };
    };

    admin = {
      existingSecret = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Existing Secret holding Forgejo's admin credentials. Null lets the bootstrap mint them.";
      };
    };

    replicas = mkOption {
      type = types.ints.positive;
      default = 1;
      description = "How many Forgejo replicas to run. Above one needs shared storage.";
    };

    gateway = gatewayOptions { inherit config; };
  };
}

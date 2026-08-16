{
  lab,
  lib,
  config,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption mkEnableOption types;
  contracts = import ../../../../../lib/contracts { inherit lib; };
  inherit (import ../../../../../lib/floe { inherit lib; }) gatewayOptions refs;
in
{
  options.floes.zot = {
    chart = mkOption {
      type = types.package;
      default = cataCharts.zot.chart;
      description = "Helm chart to install. Defaults to the chart catallaxy pins.";
    };
    domain = mkOption {
      type = types.str;
      default = "";
      description = "Hostname zot is served on. Empty disables the HTTPRoute, which is what a lab wants when the registry is reached only from inside the cluster.";
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
        description = "Issuer that signs the serving certificate. Null means no certificate is minted and TLS is somebody else's problem.";
      };
      secretName = mkOption {
        type = types.str;
        default = "zot-tls";
        description = "Secret the issued certificate lands in.";
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
        description = "Path inside the container that zot writes blobs and metadata to.";
      };
      size = mkOption {
        type = types.str;
        default = "50Gi";
        description = "Size of the volume claimed for that path.";
      };
      storageClass = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "StorageClass for the claim. Null takes the cluster default.";
      };
      dedupe = mkOption {
        type = types.bool;
        default = true;
        description = "Store one copy of a blob shared by several images. Saves space and costs write throughput.";
      };
    };

    auth = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Require credentials from an htpasswd file. Independent of `oidc`, which authenticates humans.";
      };
      htpasswdSecret = mkOption {
        type = types.str;
        default = "zot-htpasswd";
        description = "Secret holding the htpasswd file.";
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
        description = "OIDC issuer URL. Usually read from the identity floe's exports rather than written out.";
      };
      clientId = mkOption {
        type = types.str;
        default = "zot";
        description = "Client ID zot presents to the issuer.";
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
              name = mkOption {
                type = types.str;
                description = "Name of the Secret.";
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
        description = "Secret holding the OIDC client secret.";
      };
      scopes = mkOption {
        type = types.listOf types.str;
        default = [
          "openid"
          "email"
          "groups"
        ];
        description = "Scopes requested at login. `openid` alone identifies the user; `groups` is what makes the group options below do anything.";
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
      adminGroups = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Groups whose members administer the registry.";
      };
      readOnlyGroups = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Groups whose members may pull but not push.";
      };
    };

    search = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Serve the built-in web UI.";
      };
    };
    ui = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Expose the registry as a Service.";
      };
    };
    http = {
      port = mkOption {
        type = types.port;
        default = 5000;
        description = "Port that Service listens on.";
      };
    };
    replicas = mkOption {
      type = types.ints.positive;
      default = 1;
      description = "How many zot replicas to run. Above one needs storage that supports shared access.";
    };

    gateway = gatewayOptions {
      inherit lab;
    };
  };
}

{
  config,
  lib,
  lab,
  ...
}:
let
  dns = lab.dns;
in
{
  floes.netbird = {
    enable = true;
    domain = "nb.${dns.zone}";
    turn.domain = "turn.${dns.zone}";

    operator = {
      enable = true;

      autoGroupsFromJwt = [
        "netbird-users@idm.${dns.zone}"
        "netbird-admins@idm.${dns.zone}"
      ];

      adminGroupsFromJwt = [ "netbird-admins@idm.${dns.zone}" ];
    };

    dashboard = {
      enable = true;
      oidc.clientId = "netbird";
      oidc.issuerUrl = config.floes.kanidm.exports.oauth2Clients.netbird.issuer or "";
    };

    idp = {

      client = {
        issuer = config.floes.kanidm.exports.oauth2Clients.netbird.internalIssuer or "";
        clientId = "netbird";
        publicIssuer = config.floes.kanidm.exports.oauth2Clients.netbird.issuer or "";
        authorizationEndpoint = config.floes.kanidm.exports.authorizationEndpoint or "";
        tokenEndpoint = config.floes.kanidm.exports.tokenEndpoint or "";
        jwksUri = config.floes.kanidm.exports.oauth2Clients.netbird.internalJwksUri or "";
      };

      machine = {
        tokenEndpoint = config.floes.kanidm.exports.internalTokenEndpoint or "";
        tokenRef = {
          name = "netbird-bot-token";
          namespace = config.floes.kanidm.namespace;
          key = "token";
        };
      };
    };

    groups = {
      routers-mgmt = { };
      routers-apps = { };
    };

    setupKeys = {
      cluster-router-mgmt.autoGroups = [ "routers-mgmt" ];
      cluster-router-apps.autoGroups = [ "routers-apps" ];
    };

    agent = {
      enable = true;
      managementUrl = "https://nb.${dns.zone}";
      hostname = "mgmt-router";
      setupKeyRef.name = "setup-key-cluster-router-mgmt";
      advertisedRoutes = [ config.cluster.network.serviceSubnet ];
    };

    routing = {
      enable = true;

      resolverIP =
        let
          octets = lib.splitString "." (lib.head (lib.splitString "/" config.cluster.network.serviceSubnet));
        in
        lib.concatStringsSep "." ((lib.take 3 octets) ++ [ "10" ]);

      networks = {
        mesh-lab-mgmt = {
          routerGroup = "routers-mgmt";
          resources = {
            internal-gateway = {
              address = config.floes.gateway.internal.clusterIPAddress;
              sourceGroups = [
                "netbird-users@idm.${dns.zone}"
                "netbird-admins@idm.${dns.zone}"
              ];
              description = "Internal-tier entry in the mgmt cluster";
            };

            cluster-services = {
              address = config.cluster.network.serviceSubnet;
              sourceGroups = [ "netbird-admins@idm.${dns.zone}" ];
              description = "mgmt Service CIDR, admin debugging";
            };
          };
        };

        mesh-lab-apps = {
          routerGroup = "routers-apps";
          resources = {
            internal-gateway = {
              address = lab.clusters.apps.floes.gateway.exports.internalGatewayClusterIP;
              sourceGroups = [
                "netbird-users@idm.${dns.zone}"
                "netbird-admins@idm.${dns.zone}"
              ];
              description = "Internal-tier entry in the apps cluster";
            };

            cluster-services = {
              address = lab.clusters.apps.cluster.network.serviceSubnet;
              sourceGroups = [ "netbird-admins@idm.${dns.zone}" ];
              description = "apps Service CIDR, admin debugging";
            };
          };
        };
      };
    };
  };
}

{ config, lab, ... }:
let
  dns = lab.dns;
in
{
  floes.kaniop.enable = true;

  floes.kanidm = {
    enable = true;
    domain = "idm.${dns.zone}";
    tls.issuerRef = config.floes.cert-manager.exports.defaultIssuerRef;

    groups = {
      netbird-users.members = [
        "lab-admin"
        "netbird-bot"
      ];
      netbird-admins.members = [
        "lab-admin"
        "netbird-bot"
      ];
    };

    users.lab-admin = {
      displayName = "Lab Admin";
      email = "admin@example.test";
    };

    serviceAccounts.netbird-bot = {
      displayName = "Netbird Bootstrap Bot";
      entryManagedBy = "idm_admins";
      apiTokens = [
        {
          label = "netbird-bootstrap";
          purpose = "readwrite";
          secretName = "netbird-bot-token";
        }
      ];
    };

    oauth2Clients.netbird = {
      displayName = "Netbird";
      origin = "https://nb-dashboard.${dns.zone}";

      redirectUrls = config.floes.netbird.exports.oauthRedirectUrls ++ [
        "https://nb-dashboard.${dns.zone}/auth/callback"
        "https://nb-dashboard.${dns.zone}/auth/silent-callback"
      ];
      allowLocalhostRedirect = true;
      public = true;
      preferShortUsername = true;
      scopeMap = [
        {
          group = "netbird-users";
          scopes = [
            "openid"
            "email"
            "profile"
            "groups"
            "offline_access"
          ];
        }
        {
          group = "netbird-admins";
          scopes = [
            "openid"
            "email"
            "profile"
            "groups"
            "offline_access"
          ];
        }
      ];
    };
  };
}

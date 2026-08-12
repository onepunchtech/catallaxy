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

    users = {
      lab-admin = {
        displayName = "Lab Admin";
        email = "admin@${dns.zone}";
      };
      lab-dev = {
        displayName = "Developer";
        email = "dev@${dns.zone}";
      };
    };

    groups = {
      admins.members = [ "lab-admin" ];
      developers.members = [ "lab-dev" ];
      grafana-admins.members = [ "lab-admin" ];
      grafana-editors.members = [ "lab-dev" ];
    };

    oauth2Clients = {
      forgejo = {
        origin = "https://git.${dns.zone}";
        redirectUrls = [ "https://git.${dns.zone}/user/oauth2/Kanidm/callback" ];
        public = true;
        preferShortUsername = true;
        allowLocalhostRedirect = true;
        scopeMap = [
          {
            group = "admins";
            scopes = [
              "openid"
              "email"
              "profile"
              "groups"
            ];
          }
          {
            group = "developers";
            scopes = [
              "openid"
              "email"
              "profile"
              "groups"
            ];
          }
        ];
      };
      harbor = {
        origin = "https://registry.${dns.zone}";
        redirectUrls = [ "https://registry.${dns.zone}/c/oidc/callback" ];

        public = false;
        preferShortUsername = true;

        scopeMap = [
          {
            group = "admins";
            scopes = [
              "openid"
              "email"
              "profile"
              "groups"
              "offline_access"
            ];
          }
          {
            group = "developers";
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
      argocd = {
        origin = "https://argocd.${dns.zone}";
        redirectUrls = [ "https://argocd.${dns.zone}/api/dex/callback" ];
        namespace = "argocd";
        public = false;
        preferShortUsername = true;
        allowInsecureClientDisablePkce = true;
        secretTemplate = {
          "app.kubernetes.io/part-of" = "argocd";
        };
        scopeMap = [
          {
            group = "admins";
            scopes = [
              "openid"
              "email"
              "profile"
              "groups"
            ];
          }
          {
            group = "developers";
            scopes = [
              "openid"
              "email"
              "profile"
              "groups"
            ];
          }
        ];
      };
      grafana = {
        origin = "https://grafana.${dns.zone}";
        redirectUrls = [ "https://grafana.${dns.zone}/login/generic_oauth" ];
        public = true;
        preferShortUsername = true;
        scopeMap = [
          {
            group = "grafana-admins";
            scopes = [
              "openid"
              "email"
              "profile"
              "groups"
            ];
          }
          {
            group = "grafana-editors";
            scopes = [
              "openid"
              "email"
              "profile"
              "groups"
            ];
          }
        ];
      };
    };
  };
}

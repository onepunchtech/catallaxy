# Kanidm — central OIDC identity provider
{ config, lab, ... }:
let
  dns = lab.dns;
in
{
  components.kaniop.enable = true;

  components.kanidm = {
    enable = true;
    domain = "idm.${dns.zone}";
    origin = "https://idm.${dns.zone}";
    tls.issuerRef = config.components.cert-manager.ref.defaultIssuerRef;
    oauth2ClientNamespaceSelector = { }; # watch all namespaces for OAuth2Client CRs

    users = {
      lab-admin = {
        displayName = "Lab Admin";
        email = "admin@${dns.zone}";
        groups = [
          "admins"
          "grafana-admins"
        ];
      };
      lab-dev = {
        displayName = "Developer";
        email = "dev@${dns.zone}";
        groups = [
          "developers"
          "grafana-editors"
        ];
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
      zot = {
        origin = "https://registry.${dns.zone}";
        redirectUrls = [ "https://registry.${dns.zone}/oauth2/callback" ];
        public = true;
        preferShortUsername = true;
        scopeMap = [
          {
            group = "admins";
            scopes = [
              "openid"
              "email"
              "groups"
            ];
          }
          {
            group = "developers";
            scopes = [
              "openid"
              "email"
              "groups"
            ];
          }
        ];
      };
      argocd = {
        origin = "https://argocd.${dns.zone}";
        redirectUrls = [ "https://argocd.${dns.zone}/api/dex/callback" ];
        namespace = "argocd"; # CR + credential secret created in ArgoCD's namespace
        public = false;
        preferShortUsername = true;
        allowInsecureClientDisablePkce = true;
        secretTemplate = {
          "app.kubernetes.io/part-of" = "argocd"; # Dex's informer watches secrets with this label
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

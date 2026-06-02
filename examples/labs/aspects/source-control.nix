# Forgejo + PostgreSQL
{ config, lab, ... }:
let
  dns = lab.dns;
in
{
  components.cnpg = {
    enable = true;
    clusters.postgres = {
      namespace = "forgejo";
      createNamespace = true;
      instances = 1;
      storage.size = "10Gi";
      postgresql.version = "16";
    };
  };

  components.forgejo = {
    enable = true;
    domain = "git.${dns.zone}";
    tls.issuerRef = config.components.cert-manager.ref.defaultIssuerRef;
    database = {
      host = config.components.cnpg.clusters.postgres.ref.host;
      name = "app";
      user = "app";
      secretRef = {
        name = "postgres-app";
        key = "password";
      };
    };
    oidc = {
      enable = true;
      clientId = "forgejo";
      issuerUrl = config.components.kanidm.ref.oauth2Clients.forgejo.internalIssuer;
      providerName = "Kanidm";
      adminGroup = "admins";
    };
  };
}

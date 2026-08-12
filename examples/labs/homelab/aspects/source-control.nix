{ config, lab, ... }:
let
  dns = lab.dns;
in
{

  floes.reloader.enable = true;

  floes.cnpg = {
    enable = true;
    clusters.postgres = {
      namespace = "forgejo";
      createNamespace = true;
      instances = 1;
      storage.size = "10Gi";
      postgresql.version = "16";
    };
  };

  floes.forgejo = {
    enable = true;
    domain = "git.${dns.zone}";
    tls.issuerRef = config.floes.cert-manager.exports.defaultIssuerRef;
    database = {
      host = config.floes.cnpg.clusters.postgres.ref.host;
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
      issuerUrl = config.floes.kanidm.exports.oauth2Clients.forgejo.internalIssuer;
      providerName = "Kanidm";
      adminGroup = "admins";
    };
  };
}

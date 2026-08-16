{ config, lab, ... }:
let
  dns = lab.dns;
in
{
  floes.harbor = {
    enable = true;
    domain = "registry.${dns.zone}";
    tls.issuerRef = config.floes.cert-manager.exports.defaultIssuerRef;
    oidc = {
      enable = true;
      clientId = "harbor";
      issuerUrl = config.floes.kanidm.exports.oauth2Clients.harbor.issuer;

      clientSecretRef = config.floes.kanidm.exports.oauth2Clients.harbor.clientSecretRef;
      adminGroup = "admins";
    };

    # A pull-only account for the other cluster. Harbor's bootstrap Job creates
    # it through the Harbor API and writes the dockerconfigjson here.
    robots.obs-puller = {
      secretName = "harbor-obs-puller";
    };
  };

  # Publish it, so any cluster in the lab can subscribe. This side names no
  # consumer: the address is derived from where the secret lives, and whoever
  # wants it asks for it.
  floes.external-secrets.enable = true;

  # The lab's runtime store. Dev mode keeps it in memory: what it holds is
  # minted by the lab, so a fresh cluster mints it again rather than losing
  # anything that had to be kept.
  floes.openbao = {
    enable = true;
    # Exposed because obs reads the store too, not for humans to browse.
    domain = "bao.${dns.zone}";
    tls.issuerRef = config.floes.cert-manager.exports.defaultIssuerRef;
  };

  secrets.projections.openbao-root-token = {
    source = "openbao-root-token";
    namespace = "openbao";
    keys.token.from = "token";
  };

  # external-secrets authenticates to the store with the same token.
  secrets.projections.vault-token = {
    source = "openbao-root-token";
    namespace = "external-secrets";
    keys.token.from = "token";
  };

  secrets.publish.harbor-obs-puller = {
    namespace = config.floes.harbor.namespace;
  };
}

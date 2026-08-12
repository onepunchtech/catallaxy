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
  };
}

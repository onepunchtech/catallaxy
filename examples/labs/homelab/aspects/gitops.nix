{ config, lab, ... }:
let
  dns = lab.dns;
in
{

  floes.reloader.enable = true;

  floes.argocd = {
    enable = true;
    domain = "argocd.${dns.zone}";
    tls.issuerRef = config.floes.cert-manager.exports.defaultIssuerRef;
    repositories.manifests = {
      url = "https://git.${dns.zone}/infrastructure/manifests.git";
      type = "git";
    };
    oidc = {
      enable = true;
      clientId = "argocd";
      issuerUrl = config.floes.kanidm.exports.oauth2Clients.argocd.issuer;
      name = "Kanidm";
    };
  };
}

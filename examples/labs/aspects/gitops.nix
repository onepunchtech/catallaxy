# ArgoCD — GitOps delivery
{ config, lab, ... }:
let
  dns = lab.dns;
in
{
  components.argocd = {
    enable = true;
    domain = "argocd.${dns.zone}";
    tls.issuerRef = config.components.cert-manager.ref.defaultIssuerRef;
    repositories.manifests = {
      url = "https://git.${dns.zone}/infrastructure/manifests.git";
      type = "git";
    };
    oidc = {
      enable = true;
      clientId = "argocd";
      issuerUrl = config.components.kanidm.ref.oauth2Clients.argocd.issuer;
      name = "Kanidm";
      caBundleConfigMap =
        if config.components.cert-manager.selfSignedCA.enable then
          config.components.cert-manager.ref.caBundleConfigMap
        else
          null;
      caBundleKey = config.components.cert-manager.ref.caBundleKey;
    };
  };
}

# Zot OCI registry
{ config, lab, ... }:
let
  dns = lab.dns;
in
{
  components.zot = {
    enable = true;
    domain = "registry.${dns.zone}";
    tls.issuerRef = {
      name = "lab-ca";
      kind = "ClusterIssuer";
    };
    oidc = {
      enable = true;
      clientId = "zot";
      issuerUrl = config.components.kanidm.ref.oauth2Clients.zot.issuer;
      adminGroups = [ "admins" ];
      readOnlyGroups = [ "developers" ];
    };
  };
}

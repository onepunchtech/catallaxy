{
  config,
  lib,
  lab,
  ...
}:
let
  dns = lab.dns;
in
{
  floes.gateway = {
    enable = true;
    tls = {
      enable = true;
      domain = dns.zone;
      issuerRef = config.floes.cert-manager.exports.defaultIssuerRef;
      passthrough.enable = true;
    };
  };

  floes.cert-manager = {
    enable = true;
    selfSignedCA.enable = true;
  };

  floes.trust-manager.enable = true;

  bundles.coredns-lab-dns.resources = lib.mkIf dns.enable {
    coredns-custom = {
      apiVersion = "v1";
      kind = "ConfigMap";
      metadata = {
        name = "coredns-custom";
        namespace = "kube-system";
      };
      data = {
        "lab.server" = ''
          ${dns.zone}:53 {
            errors
            cache 30
            forward . ${dns.server}:${toString dns.port}
          }
        '';
      };
    };
  };

  floes.external-dns = lib.mkIf dns.enable {
    enable = true;
    provider = "rfc2136";
    domainFilters = [ dns.zone ];
    policy = "sync";
    logLevel = "debug";
    rfc2136 = {
      host = dns.server;
      port = dns.port;
      zone = dns.zone;
      tsigKeyname = dns.tsigKeyname;
      tsigSecret = dns.tsigSecret;
      tsigSecretAlg = "hmac-sha256";
    };
  };
}

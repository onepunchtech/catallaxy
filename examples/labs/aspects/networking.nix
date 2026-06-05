# Gateway API, TLS, and DNS
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
  components.gateway = {
    enable = true;
    tls = {
      enable = true;
      domain = dns.zone;
      issuerRef = config.components.cert-manager.ref.defaultIssuerRef;
      passthrough.enable = true;
    };
  };

  components.cert-manager = {
    enable = true;
    selfSignedCA.enable = true;
  };

  components.trust-manager.enable = true;

  # Forward lab DNS zone to the local Knot DNS server so pods can resolve
  # lab domains (e.g., grafana in obs cluster can reach idm.homelab.test).
  # Only applies when running a local DNS server (lab.dns.enable = true).
  # k3s CoreDNS imports from coredns-custom ConfigMap via:
  #   import /etc/coredns/custom/*.server
  phases.networking.bundles.coredns-lab-dns.resources = lib.mkIf dns.enable {
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

  # Local dev: RFC2136 against Knot DNS
  # Prod clusters override with their own external-dns config (e.g. Cloudflare)
  components.external-dns = lib.mkIf dns.enable {
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

# Gateway API, TLS, and DNS
{ lab, ... }:
let
  dns = lab.dns;
in
{
  components.gateway = {
    enable = true;
    tls = {
      enable = true;
      domain = dns.zone;
      passthrough.enable = true;
    };
  };

  components.cert-manager = {
    enable = true;
    selfSignedCA.enable = true;
  };

  components.trust-manager.enable = true;

  # Forward lab DNS zone to the Knot DNS server so pods can resolve
  # lab domains (e.g., grafana in obs cluster can reach idm.homelab.test).
  # Knot stores real Docker-network IPs published by external-dns.
  # k3s CoreDNS imports from coredns-custom ConfigMap via:
  #   import /etc/coredns/custom/*.server
  phases.networking.bundles.coredns-lab-dns.resources = {
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

  components.external-dns = {
    enable = dns.enable;
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

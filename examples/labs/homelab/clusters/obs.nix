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
  imports = [
    ../aspects/networking.nix
    ../aspects/monitoring.nix
  ];

  cluster.name = "obs";
  cluster.kubernetes = {
    distribution = "k3s";
    controlPlanes = 1;
    workers = 0;
  };

  floes.otel-collector = {
    enable = true;
    agent.enable = true;
    gateway = {
      enable = true;
      replicas = lib.mkDefault 2;
      external = {
        enable = true;
        domain = "otel.${dns.zone}";
        tls.issuerRef = config.floes.cert-manager.exports.defaultIssuerRef;
      };
    };
    exporters = {
      otlp.endpoint = config.floes.tempo.exports.otlpGrpc;
      prometheus = {
        enable = true;
        endpoint = config.floes.prometheus.exports.remoteWriteUrl;
      };
      loki = {
        enable = true;
        endpoint = config.floes.loki.exports.otlpUrl;
      };
    };
  };

  floes.prometheus.gateway = {
    enable = true;
    domain = "prometheus-rw.${dns.zone}";
  };

}

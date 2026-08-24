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

  # The registry credential core publishes. It is minted at runtime, so it
  # cannot be authored and projected the way a pre-existing secret would be.
  floes.external-secrets.enable = true;

  # Reading anything core published means authenticating to the store, and
  # the store is a lab secret rather than a cluster one, so obs projects the
  # same token core does. Without it obs's store reports
  # `InvalidProviderConfig` and every subscription below it stays unresolved.
  secrets.projections.vault-token = {
    source = "openbao-root-token";
    namespace = "external-secrets";
    keys.token.from = "token";
  };

  secrets.subscribe.harbor-obs-puller = {
    from = "core";
    namespace = "default";
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

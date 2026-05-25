# Observability cluster — monitoring + telemetry gateway
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

  # OTEL gateway — receives telemetry from other clusters
  components.otel-collector = {
    enable = true;
    agent.enable = true;
    gateway = {
      enable = true;
      replicas = lib.mkDefault 2;
      external = {
        enable = true;
        domain = "otel.${dns.zone}";
        tls.issuerRef = {
          name = "lab-ca";
          kind = "ClusterIssuer";
        };
      };
    };
    exporters = {
      otlp.endpoint = config.components.tempo.ref.otlpGrpc;
      prometheus = {
        enable = true;
        endpoint = config.components.prometheus.ref.remoteWriteUrl;
      };
      loki = {
        enable = true;
        endpoint = config.components.loki.ref.otlpUrl;
      };
    };
  };

  # Expose remote-write endpoint for cross-cluster metrics ingestion
  components.prometheus.gateway = {
    enable = true;
    domain = "prometheus-rw.${dns.zone}";
  };

  components.pki-auth.enable = false;
  components.oidc.enable = false;
}

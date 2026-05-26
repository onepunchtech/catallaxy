# Core cluster — identity, git, registry, gitops
{ config, lab, ... }:
{
  imports = [
    ../aspects/networking.nix
    ../aspects/identity.nix
    ../aspects/gitops.nix
    ../aspects/source-control.nix
    ../aspects/registry.nix
    ../aspects/backups.nix
  ];

  cluster.name = "core";
  cluster.kubernetes = {
    distribution = "k3s";
    controlPlanes = 1;
    workers = 0;
  };

  # Prometheus: scrape + remote-write to obs for multi-cluster dashboards
  components.prometheus = {
    enable = true;
    alertmanager.enable = false;
    grafana.enable = false;
    storage.size = "1Gi";
    retention = "2h";
    externalLabels.cluster = "core";
    remoteWrite = [
      {
        url = "https://prometheus-rw.${lab.dns.zone}/api/v1/write";
        tlsConfig.ca.configMap = {
          name = config.components.cert-manager.ref.caBundleConfigMap;
          key = config.components.cert-manager.ref.caBundleKey;
        };
      }
    ];
  };

  # OTEL: logs + traces only (metrics handled by Prometheus remote-write)
  components.otel-collector = {
    enable = true;
    tls.caBundleConfigMap = config.components.cert-manager.ref.caBundleConfigMap;
    tls.caBundleKey = config.components.cert-manager.ref.caBundleKey;
    agent = {
      enable = true;
      excludeNamespaces = [ "kube-system" ];
    };
    gateway = {
      enable = true;
      replicas = 1;
    };
    exporters = {
      otlp.endpoint = "otel.${lab.dns.zone}:443";
    };
  };

  components.pki-auth.enable = false;
  components.oidc.enable = false;
}

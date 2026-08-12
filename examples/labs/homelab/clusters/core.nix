{
  config,
  lib,
  lab,
  ...
}:
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

  floes.prometheus = {
    enable = true;
    alertmanager.enable = false;
    grafana.enable = false;
    storage.size = "1Gi";
    retention = "2h";
    externalLabels.cluster = "core";
    remoteWrite = [
      (
        {
          url = "https://prometheus-rw.${lab.dns.zone}/api/v1/write";
        }

        // lib.optionalAttrs (config.floes.cert-manager.exports.caBundle != null) {
          tlsConfig.ca.configMap = {
            inherit (config.floes.cert-manager.exports.caBundle) name key;
          };
        }
      )
    ];
  };

  floes.otel-collector = {
    enable = true;
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

}

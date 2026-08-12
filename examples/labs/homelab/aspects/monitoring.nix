{
  config,
  lab,
  ...
}:
let
  dns = lab.dns;
in
{
  floes.prometheus = {
    enable = true;
    grafana.forceDeployDashboards = true;
    externalLabels.cluster = config.cluster.name;

    defaultRules = {
      etcd = false;
      kubeSchedulerAlerting = false;
      kubeSchedulerRecording = false;
      kubeProxy = false;
      kubeControllerManager = false;
    };
  };
  floes.loki.enable = true;
  floes.tempo.enable = true;

  floes.reloader.enable = true;

  floes.grafana = {
    enable = true;
    domain = "grafana.${dns.zone}";
    sidecar.dashboards.searchNamespace = "ALL";
    plugins = [ "grafana-lokiexplore-app" ];
    tls.issuerRef = config.floes.cert-manager.exports.defaultIssuerRef;
    oidc = {
      enable = true;
      name = "Kanidm";
      clientId = "grafana";
      issuerUrl = lab.clusters.core.floes.kanidm.exports.externalUrl;

      roleAttributePath = "contains(join(' ', groups[*]), 'grafana-admins') && 'Admin' || contains(join(' ', groups[*]), 'grafana-editors') && 'Editor' || 'Viewer'";
    };
  };
}

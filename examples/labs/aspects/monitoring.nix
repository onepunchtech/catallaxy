# Prometheus, Loki, Tempo, Grafana
{
  config,
  lab,
  ...
}:
let
  dns = lab.dns;
in
{
  components.prometheus = {
    enable = true;
    grafana.forceDeployDashboards = true;
    externalLabels.cluster = config.cluster.name;
    # Disable alert rules for components not exposed in k3d/k3s
    defaultRules = {
      etcd = false;
      kubeSchedulerAlerting = false;
      kubeSchedulerRecording = false;
      kubeProxy = false;
      kubeControllerManager = false;
    };
  };
  components.loki.enable = true;
  components.tempo.enable = true;

  components.grafana = {
    enable = true;
    domain = "grafana.${dns.zone}";
    sidecar.dashboards.searchNamespace = "ALL";
    plugins = [ "grafana-lokiexplore-app" ];
    tls.issuerRef = config.components.cert-manager.ref.defaultIssuerRef;
    oidc = {
      enable = true;
      name = "Kanidm";
      clientId = "grafana";
      issuerUrl = lab.clusters.core.components.kanidm.ref.externalUrl;
      tlsCaBundleConfigMap = {
        name = config.components.cert-manager.ref.caBundleConfigMap;
        key = config.components.cert-manager.ref.caBundleKey;
      };
      # Kanidm returns group SPNs (e.g. grafana-admins@homelab.test), so use
      # join + contains for substring matching instead of exact array membership.
      roleAttributePath = "contains(join(' ', groups[*]), 'grafana-admins') && 'Admin' || contains(join(' ', groups[*]), 'grafana-editors') && 'Editor' || 'Viewer'";
    };
  };
}

{
  config,
  lab,
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption mkEnableOption types;
  inherit (import ../../../../../lib/floe { inherit lib; }) gatewayOptions;
in
{
  options.floes.prometheus = {
    chart = mkOption {
      type = types.package;
      default = cataCharts.prometheus.chart;
      description = "kube-prometheus-stack Helm chart derivation (default: cataCharts.prometheus)";
    };

    retention = mkOption {
      type = types.str;
      default = "15d";
      description = "Metrics retention period";
    };

    storage = {
      size = mkOption {
        type = types.str;
        default = "50Gi";
        description = "PVC size for Prometheus TSDB";
      };

      storageClass = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Storage class for PVC";
      };
    };

    replicas = mkOption {
      type = types.ints.positive;
      default = 1;
      description = "Number of Prometheus replicas";
    };

    alertmanager = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Alertmanager";
      };
    };

    nodeExporter = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Node Exporter for host metrics";
      };
    };

    kubeStateMetrics = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable kube-state-metrics";
      };
    };

    grafana = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable the bundled Grafana (disable when using the grafana component)";
      };

      forceDeployDashboards = mkOption {
        type = types.bool;
        default = false;
        description = "Deploy Kubernetes dashboard ConfigMaps even when bundled Grafana is disabled";
      };
    };

    externalLabels = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "External labels added to all metrics (e.g., cluster name for multi-cluster)";
    };

    remoteWrite = mkOption {
      type = types.listOf types.attrs;
      default = [ ];
      description = "Remote write endpoints for forwarding metrics";
    };

    serviceMonitorSelector = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Label selector for ServiceMonitors (empty = all)";
    };

    defaultRules = mkOption {
      type = types.attrsOf types.bool;
      default = { };
      description = "Override default alert rule groups (e.g., { kubeEtcd = false; } to disable etcd rules)";
    };

    gateway = gatewayOptions { inherit config; } // {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Expose Prometheus remote-write endpoint externally via Gateway API";
      };
      domain = mkOption {
        type = types.str;
        default = "";
        description = "Domain for external remote-write ingestion";
      };
    };
  };
}

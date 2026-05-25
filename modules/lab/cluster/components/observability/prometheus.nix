{
  config,
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    optionalAttrs
    ;
  cfg = config.components.prometheus;

  # Chart reference with fallback
  chartRef = cfg.chart;
in
{
  # =========================================================================
  # PART 1: High-level options
  # =========================================================================

  options.components.prometheus = {
    enable = mkEnableOption "Prometheus (kube-prometheus-stack)";

    phase = mkOption {
      type = types.str;
      default = "infrastructure";
      description = "Deployment phase this component belongs to";
    };

    version = mkOption {
      type = types.str;
      default = "65.1.0";
      description = "kube-prometheus-stack Helm chart version";
    };

    chart = mkOption {
      type = types.package;
      default = cataCharts.prometheus.chart;
      description = "kube-prometheus-stack Helm chart derivation (default: cataCharts.prometheus)";
    };

    namespace = mkOption {
      type = types.str;
      default = "prometheus";
      description = "Namespace for Prometheus";
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

    # Disable the bundled Grafana — we have our own component
    grafana = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable the bundled Grafana (disable when using components.grafana)";
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

    gateway = {
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
      gatewayRef = mkOption {
        type = types.str;
        default = "default-gateway";
      };
      gatewayNamespace = mkOption {
        type = types.nullOr types.str;
        default = "kube-system";
      };
    };

    ref = mkOption {
      type = types.attrs;
      readOnly = true;
      description = "Computed references for Prometheus";
    };
  };

  # =========================================================================
  # PART 2: Computed refs
  # =========================================================================

  # =========================================================================
  # PART 3: Phase writer
  # =========================================================================

  config = lib.mkMerge [
    {
      components.prometheus.ref =
        let
          host = "prometheus-kube-prometheus-prometheus.${cfg.namespace}.svc.cluster.local";
        in
        {
          inherit host;
          namespace = cfg.namespace;
          port = 9090;
          url = "http://${host}:9090";
          remoteWriteUrl = "http://${host}:9090/api/v1/write";
        };
    }
    (mkIf cfg.enable {
      # CRDs must be in the crds phase so they exist before the chart is applied
      phases.crds.bundles.prometheus-crds.yamls = [ cataCharts.prometheus.crds ];

      # kube-prometheus-stack helm chart
      phases.${cfg.phase}.bundles.prometheus = {
        helmCharts.prometheus = {
          chart = chartRef;
          releaseName = "prometheus";
          namespace = cfg.namespace;
          createNamespace = true;
          kustomize = {
            enable = true;
            patches = [
              {
                # Prevent kapp from injecting its labels into Service selectors.
                # Prometheus Operator creates the pods, so they won't have kapp labels.
                target = {
                  kind = "Service";
                };
                patch = builtins.toJSON [
                  {
                    op = "add";
                    path = "/metadata/annotations/kapp.k14s.io~1disable-label-scoping";
                    value = "";
                  }
                ];
              }
            ];
          };
          values = {
            # CRDs managed separately in crds phase
            crds.enabled = false;
            prometheus = {
              prometheusSpec = {
                replicas = cfg.replicas;
                retention = cfg.retention;

                storageSpec.volumeClaimTemplate.spec = {
                  accessModes = [ "ReadWriteOnce" ];
                  resources.requests.storage = cfg.storage.size;
                }
                // optionalAttrs (cfg.storage.storageClass != null) {
                  storageClassName = cfg.storage.storageClass;
                };

                remoteWrite = cfg.remoteWrite;
                externalLabels = cfg.externalLabels;
                enableRemoteWriteReceiver = true;
              }
              // optionalAttrs (cfg.serviceMonitorSelector != { }) {
                serviceMonitorSelector.matchLabels = cfg.serviceMonitorSelector;
              };
            };

            alertmanager.enabled = cfg.alertmanager.enable;
            nodeExporter.enabled = cfg.nodeExporter.enable;
            kubeStateMetrics.enabled = cfg.kubeStateMetrics.enable;
            grafana = {
              enabled = cfg.grafana.enable;
              forceDeployDashboards = cfg.grafana.forceDeployDashboards;
            };
          }
          // optionalAttrs (cfg.defaultRules != { }) {
            defaultRules.rules = cfg.defaultRules;
          };
        };

        # External remote-write ingestion endpoint via Gateway API
        resources = optionalAttrs (cfg.gateway.enable && cfg.gateway.domain != "") {
          "prometheus-remote-write-httproute" = {
            apiVersion = "gateway.networking.k8s.io/v1";
            kind = "HTTPRoute";
            metadata = {
              name = "prometheus-remote-write";
              namespace = cfg.namespace;
            };
            spec = {
              parentRefs = [
                (
                  {
                    name = cfg.gateway.gatewayRef;
                  }
                  // optionalAttrs (cfg.gateway.gatewayNamespace != null) {
                    namespace = cfg.gateway.gatewayNamespace;
                  }
                )
              ];
              hostnames = [ cfg.gateway.domain ];
              rules = [
                {
                  matches = [
                    {
                      path = {
                        type = "PathPrefix";
                        value = "/api/v1/write";
                      };
                    }
                  ];
                  backendRefs = [
                    {
                      name = "prometheus-kube-prometheus-prometheus";
                      port = 9090;
                    }
                  ];
                }
              ];
            };
          };
        };

        # Namespace creation
        createNamespaces = [ cfg.namespace ];
      };
    })
  ];
}

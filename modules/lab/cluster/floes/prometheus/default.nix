{
  config,
  lib,
  pkgs,
  cataCharts,
  k8sSpecs,
  k8sHelpers,
  lab,
  ...
}:

let
  inherit ((import ../../../../../lib/floe { inherit lib; })) floeOptions refs;
  cfg = config.floes.prometheus;
in
{
  imports = [
    (floeOptions {
      name = "prometheus";
      version = "65.1.0";
    })
    ./options.nix
  ];

  options.floes.prometheus.exports = {
    metrics = lib.mkOption {
      type = refs.mkCapability {
        scrapeReady = refs.tokenOption ''"Prometheus is scraping and accepting remote-write."'';
        crdsEstablished = refs.tokenOption ''"The monitoring.coreos.com CRDs are established." Needed before emitting a ServiceMonitor or PrometheusRule.'';
      };
      default = null;
      description = ''
        Metrics collection, or null when this floe is off. Consumers
        that export metrics or emit a ServiceMonitor assert on this
        rather than on `floes.prometheus.enable`.
      '';
    };
    host = lib.mkOption {
      type = lib.types.str;
      default = "prometheus-kube-prometheus-prometheus.prometheus.svc.cluster.local";
      description = "In-cluster Prometheus service DNS name.";
    };
    namespace = lib.mkOption {
      type = lib.types.str;
      default = "prometheus";
      description = "Namespace Prometheus runs in.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 9090;
      description = "Prometheus HTTP API port.";
    };
    url = lib.mkOption {
      type = lib.types.str;
      default = "http://prometheus-kube-prometheus-prometheus.prometheus.svc.cluster.local:9090";
      description = "Prometheus base URL (http://host:port).";
    };
    remoteWriteUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://prometheus-kube-prometheus-prometheus.prometheus.svc.cluster.local:9090/api/v1/write";
      description = "Prometheus remote-write endpoint (/api/v1/write).";
    };
  };

  config = lib.mkIf cfg.enable (
    let
      inherit (lib) optionalAttrs;

      host = "prometheus-kube-prometheus-prometheus.${cfg.namespace}.svc.cluster.local";

      # Prometheus exposes only its remote-write endpoint, not a UI, so the
      # route is path-scoped and there is no certificate: the Gateway's own
      # wildcard terminates for it.
      httpRouteResources = k8sHelpers.mkGatewayExposure {
        name = "prometheus-remote-write";
        routeName = "prometheus-remote-write-httproute";
        namespace = cfg.namespace;
        inherit (cfg.gateway) domain;
        inherit (cfg) gateway;
        inherit (config.floes.gateway.exports) internalGatewayName;
        sectionName = config.floes.gateway.exports.terminatingListenerName or "https";
        pathPrefix = "/api/v1/write";
        backend = {
          name = "prometheus-kube-prometheus-prometheus";
          port = 9090;
        };
      };

    in
    {

      assertions = [
        {
          assertion = config.floes.cert-manager.exports.internalIssuerRef ? name;
          message = ''
            floes.prometheus requires an internal (self-signed) CA
            to sign the prometheus-operator's admission-webhook TLS
            certificate. This cluster's `floes.cert-manager` has no
            self-signed CA configured.

            Enable it in the env for this cluster:
              floes.cert-manager.selfSignedCA.enable = true;
              floes.cert-manager.selfSignedCA.intermediate.enable = true;
            and project the lab-global CA into the cluster's
            cert-manager namespace with `secrets.projections`, one entry
            for the root CA secret and one for the intermediate.

            ACME issuers are NOT usable here: they reject internal
            `*.svc` SANs ("Domain name needs at least one dot" / "does
            not end with a valid public suffix").
          '';
        }
      ];

      floes.prometheus.exports = {
        metrics = {
          scrapeReady = "prometheus/scrape/ready";
          crdsEstablished = "prometheus/crds/established";
        };
        inherit host;
        inherit (cfg) namespace;
        port = 9090;
        url = "http://${host}:9090";
        remoteWriteUrl = "http://${host}:9090/api/v1/write";
      };

      floes.gateway.internalHostnames =
        if cfg.gateway.enable && cfg.gateway.tier == "internal" && cfg.gateway.domain != "" then
          [ cfg.gateway.domain ]
        else
          [ ];

      floes.prometheus.network = {

        declared = true;

        serves.api.port = 9090;

        serves.operatorWebhook = {

          port = 443;

          fromApiServer = true;

        };

      };

      floes.prometheus.imagesComplete = true;

      floes.prometheus.images.operator = {

        registry = "quay.io";

        repository = "prometheus-operator/prometheus-operator";

        tag = "v0.82.2";

      };

      floes.prometheus.images.nodeExporter = {

        registry = "quay.io";

        repository = "prometheus/node-exporter";

        tag = "v1.9.1";

      };

      floes.prometheus.images.kubeStateMetrics = {

        registry = "registry.k8s.io";

        repository = "kube-state-metrics/kube-state-metrics";

        tag = "v2.15.0";

      };

      floes.prometheus.bundles.prometheus-crds.yamls = [ cataCharts.prometheus.crds ];
      floes.prometheus.bundles.prometheus-crds.provides = [ "prometheus/crds/established" ];

      floes.prometheus.bundles.prometheus = {
        helmCharts.prometheus = {
          chart = cfg.chart;
          releaseName = "prometheus";
          namespace = cfg.namespace;
          createNamespace = true;
          kustomize = {
            enable = true;
            patches = [
              {

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

            crds.enabled = false;

            prometheusOperator.admissionWebhooks = {
              certManager = {
                enabled = true;

                issuerRef = config.floes.cert-manager.exports.internalIssuerRef;
              };
              patch.enabled = false;
            };
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

        resources = httpRouteResources;

        createNamespaces = [ cfg.namespace ];

        requires = [
          "prometheus/crds/established"
        ]
        ++ [
          "certificate-issuance/webhook/ready"
          "certificate-issuance/issuer/ready"
        ];
        provides = [
          "prometheus/scrape/ready"
          "metrics/scrape/ready"
        ];
        readyProbe = {
          kind = "condition";
          resource = "statefulset/prometheus-prometheus-kube-prometheus-prometheus";
          namespace = cfg.namespace;
          condition = "Available";
          timeout = "10m";
        };
      };
    }
  );
}

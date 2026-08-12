{
  config,
  lib,
  pkgs,
  cataCharts,
  k8sSpecs,
  k8sHelpers,
  ...
}@__floeModuleArgs:

let
  inherit ((import ../../../../../lib/floe { inherit lib; })) mkFloe refs;
in
(mkFloe {
  name = "prometheus";
  version = "65.1.0";
  imports = [ ./options.nix ];

  requires = [
    "gateway"
    "cert-manager"
  ];

  exports =
    { lib, ... }:
    {
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
  module =
    {
      config,
      lib,
      cfg,
      peers,
      cataCharts,
      ...
    }:
    let
      inherit (lib) optionalAttrs;

      host = "prometheus-kube-prometheus-prometheus.${cfg.namespace}.svc.cluster.local";

      httpRouteResources = optionalAttrs (cfg.gateway.enable && cfg.gateway.domain != "") {
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
                  name =
                    if cfg.gateway.tier == "internal" then
                      config.floes.gateway.exports.internalGatewayName
                    else
                      cfg.gateway.gatewayRef;

                  sectionName = config.floes.gateway.exports.terminatingListenerName or "https";
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

      bundles.prometheus-crds.yamls = [ cataCharts.prometheus.crds ];
      bundles.prometheus-crds.provides = [ "prometheus/crds/established" ];

      bundles.prometheus = {
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
        ++ refs.needs peers.cert-manager.issuance "webhookReady"
        ++ refs.needs peers.gateway.routing "publicReady";
        provides = [ "prometheus/scrape/ready" ];
        readyProbe = {
          kind = "condition";
          resource = "statefulset/prometheus-prometheus-kube-prometheus-prometheus";
          namespace = cfg.namespace;
          condition = "Available";
          timeout = "10m";
        };
      };
    };
})
  __floeModuleArgs

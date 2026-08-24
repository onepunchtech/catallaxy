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
  inherit ((import ../../../../../lib/floe { inherit lib; })) floeOptions;
  cfg = config.floes.otel-collector;
in
{
  imports = [
    (floeOptions {
      name = "otel-collector";
      version = "0.96.0";
    })
    ./options.nix
  ];

  options.floes.otel-collector.exports = {
    namespace = lib.mkOption {
      type = lib.types.str;
      default = "otel-collector";
      description = "Namespace the collector runs in.";
    };
    host = lib.mkOption {
      type = lib.types.str;
      default = "otel-gateway-opentelemetry-collector.otel-collector.svc.cluster.local";
      description = "In-cluster DNS name of the gateway Service.";
    };
    otlpGrpc = lib.mkOption {
      type = lib.types.str;
      default = "otel-gateway-opentelemetry-collector.otel-collector.svc.cluster.local:4317";
      description = "host:port a peer sends OTLP gRPC to.";
    };
    otlpHttp = lib.mkOption {
      type = lib.types.str;
      default = "http://otel-gateway-opentelemetry-collector.otel-collector.svc.cluster.local:4318";
      description = "Full URL a peer sends OTLP HTTP to.";
    };
  };

  config = lib.mkIf cfg.enable (
    let
      inherit (lib)
        optional
        optionalAttrs
        optionals
        ;

      chartRef = cfg.chart;

      agentGatewayEndpoint =
        if cfg.agent.gateway.endpoint != null then
          cfg.agent.gateway.endpoint
        else
          "otel-gateway-opentelemetry-collector.${cfg.namespace}.svc.cluster.local:${toString cfg.ports.otlpGrpc}";

      excludeNamespaces = [ cfg.namespace ] ++ cfg.agent.excludeNamespaces;
      excludePatterns = map (ns: "/var/log/pods/${ns}_*/*/*.log") excludeNamespaces;

      includePatterns =
        if cfg.agent.namespaces == [ ] then
          [ "/var/log/pods/*/*/*.log" ]
        else
          map (ns: "/var/log/pods/${ns}_*/*/*.log") cfg.agent.namespaces;

      agentConfig = {
        mode = "daemonset";
        image.repository = "otel/opentelemetry-collector-contrib";

        resources = {
          requests = {
            cpu = cfg.agent.resources.requests.cpu;
            memory = cfg.agent.resources.requests.memory;
          };
          limits = {
            cpu = cfg.agent.resources.limits.cpu;
            memory = cfg.agent.resources.limits.memory;
          };
        };

        ports = {
          otlp.enabled = false;
          otlp-http.enabled = false;
        };

        extraVolumes = [
          {
            name = "varlogpods";
            hostPath = {
              path = "/var/log/pods";
              type = "Directory";
            };
          }
          {
            name = "varlogcontainers";
            hostPath = {
              path = "/var/log/containers";
              type = "Directory";
            };
          }
        ];

        extraVolumeMounts = [
          {
            name = "varlogpods";
            mountPath = "/var/log/pods";
            readOnly = true;
          }
          {
            name = "varlogcontainers";
            mountPath = "/var/log/containers";
            readOnly = true;
          }
        ];

        config = {
          receivers = {
            filelog = {
              include = includePatterns;
              exclude = excludePatterns;
              include_file_path = true;
              include_file_name = false;
              start_at = "end";

              operators = [
                {
                  type = "regex_parser";
                  id = "extract_metadata_from_filepath";
                  regex = ''^/var/log/pods/(?P<namespace>[^_]+)_(?P<pod_name>[^_]+)_(?P<uid>[^/]+)/(?P<container_name>[^/]+)/.*\.log$'';
                  parse_from = "attributes[\"log.file.path\"]";
                }
                {
                  type = "move";
                  from = "attributes.namespace";
                  to = "resource[\"k8s.namespace.name\"]";
                }
                {
                  type = "move";
                  from = "attributes.pod_name";
                  to = "resource[\"k8s.pod.name\"]";
                }
                {
                  type = "move";
                  from = "attributes.container_name";
                  to = "resource[\"k8s.container.name\"]";
                }
                {
                  type = "move";
                  from = "attributes.uid";
                  to = "resource[\"k8s.pod.uid\"]";
                }
              ];
            };
          };

          processors = {
            batch = {
              timeout = "5s";
              send_batch_size = 1000;
            };
            k8sattributes = {
              auth_type = "serviceAccount";
              passthrough = false;
              extract = {
                metadata = [
                  "k8s.namespace.name"
                  "k8s.pod.name"
                  "k8s.pod.uid"
                  "k8s.deployment.name"
                  "k8s.statefulset.name"
                  "k8s.daemonset.name"
                  "k8s.job.name"
                  "k8s.cronjob.name"
                  "k8s.node.name"
                ];
                labels = [
                  {
                    tag_name = "app";
                    key = "app";
                    from = "pod";
                  }
                  {
                    tag_name = "app.kubernetes.io/name";
                    key = "app.kubernetes.io/name";
                    from = "pod";
                  }
                  {
                    tag_name = "app.kubernetes.io/component";
                    key = "app.kubernetes.io/component";
                    from = "pod";
                  }
                ];
              };
              pod_association = [
                {
                  sources = [
                    {
                      from = "resource_attribute";
                      name = "k8s.pod.uid";
                    }
                  ];
                }
              ];
            };
            memory_limiter = {
              check_interval = "1s";
              limit_mib = 200;
              spike_limit_mib = 50;
            };
          };

          exporters = {
            otlp = {
              endpoint = agentGatewayEndpoint;
              tls.insecure = true;
            };
          };

          service.pipelines.logs = {
            receivers = [ "filelog" ];
            processors = [
              "memory_limiter"
              "k8sattributes"
              "batch"
            ];
            exporters = [ "otlp" ];
          };
        };

        clusterRole = {
          create = true;
          rules = [
            {
              apiGroups = [ "" ];
              resources = [
                "pods"
                "namespaces"
                "nodes"
              ];
              verbs = [
                "get"
                "watch"
                "list"
              ];
            }
            {
              apiGroups = [ "apps" ];
              resources = [
                "deployments"
                "replicasets"
                "statefulsets"
                "daemonsets"
              ];
              verbs = [
                "get"
                "watch"
                "list"
              ];
            }
            {
              apiGroups = [ "batch" ];
              resources = [
                "jobs"
                "cronjobs"
              ];
              verbs = [
                "get"
                "watch"
                "list"
              ];
            }
          ];
        };
      };

      caBundle = cfg.tls.caBundle;
      hasCaBundle = caBundle != null;
      caCertPath = "/etc/ssl/certs/lab-ca.crt";

      exporterTls = if hasCaBundle then { ca_file = caCertPath; } else { insecure = true; };

      otlpExporter = optionalAttrs (cfg.exporters.otlp.endpoint != null) {
        otlp = {
          endpoint = cfg.exporters.otlp.endpoint;
          tls = exporterTls;
        };
      };

      otlphttpExporter = optionalAttrs (cfg.exporters.otlphttp.endpoint != null) {
        otlphttp = {
          endpoint = cfg.exporters.otlphttp.endpoint;
          tls = exporterTls;
        };
      };

      prometheusExporter = optionalAttrs cfg.exporters.prometheus.enable {
        prometheusremotewrite = {
          endpoint = cfg.exporters.prometheus.endpoint;
          tls = exporterTls;
        };
      };

      lokiExporter = optionalAttrs cfg.exporters.loki.enable {
        "otlphttp/loki" = {
          endpoint = cfg.exporters.loki.endpoint;
          tls = exporterTls;
        };
      };

      gatewayExporters = otlpExporter // otlphttpExporter // prometheusExporter // lokiExporter;

      traceExporters =
        optionals (cfg.exporters.otlp.endpoint != null) [ "otlp" ]
        ++ optionals (cfg.exporters.otlphttp.endpoint != null) [ "otlphttp" ];
      metricExporters =
        optionals cfg.exporters.prometheus.enable [ "prometheusremotewrite" ]
        ++ optionals (cfg.exporters.otlp.endpoint != null) [ "otlp" ]
        ++ optionals (cfg.exporters.otlphttp.endpoint != null) [ "otlphttp" ];
      logExporters =
        optionals cfg.exporters.loki.enable [ "otlphttp/loki" ]
        ++ optionals (cfg.exporters.otlp.endpoint != null && !cfg.exporters.loki.enable) [ "otlp" ]
        ++ optionals (cfg.exporters.otlphttp.endpoint != null) [ "otlphttp" ];

      gatewayPipelines =
        { }
        // optionalAttrs (traceExporters != [ ]) {
          traces = {
            receivers = [ "otlp" ];
            processors = [
              "memory_limiter"
              "batch"
            ];
            exporters = traceExporters;
          };
        }
        // optionalAttrs (metricExporters != [ ]) {
          metrics = {
            receivers = [ "otlp" ];
            processors = [
              "memory_limiter"
              "batch"
            ];
            exporters = metricExporters;
          };
        }
        // optionalAttrs (logExporters != [ ]) {
          logs = {
            receivers = [ "otlp" ];
            processors = [
              "memory_limiter"
              "batch"
            ];
            exporters = logExporters;
          };
        };

      gatewayConfig = {
        mode = "deployment";
        replicaCount = cfg.gateway.replicas;
        image.repository = "otel/opentelemetry-collector-contrib";

        extraVolumes = optionals hasCaBundle [
          {
            name = "ca-bundle";
            configMap.name = caBundle.name;
          }
        ];

        extraVolumeMounts = optionals hasCaBundle [
          {
            name = "ca-bundle";
            mountPath = caCertPath;
            subPath = caBundle.key;
            readOnly = true;
          }
        ];

        resources = {
          requests = {
            cpu = cfg.gateway.resources.requests.cpu;
            memory = cfg.gateway.resources.requests.memory;
          };
          limits = {
            cpu = cfg.gateway.resources.limits.cpu;
            memory = cfg.gateway.resources.limits.memory;
          };
        };

        ports = {
          otlp = {
            enabled = true;
            appProtocol = "kubernetes.io/h2c";
          };
          otlp-http.enabled = true;
        };

        config = {
          receivers = {
            otlp.protocols = {
              grpc.endpoint = "0.0.0.0:${toString cfg.ports.otlpGrpc}";
              http.endpoint = "0.0.0.0:${toString cfg.ports.otlpHttp}";
            };
          };
          processors = {
            batch = {
              timeout = "5s";
              send_batch_size = 1000;
            };
            memory_limiter = {
              check_interval = "1s";
              limit_mib = 400;
              spike_limit_mib = 100;
            };
          };
          exporters = gatewayExporters;
          service.pipelines = gatewayPipelines;
        };
      };

      gatewayHost = "otel-gateway-opentelemetry-collector.${cfg.namespace}.svc.cluster.local";
    in
    {
      floes.otel-collector.exports = {
        inherit (cfg) namespace;
        host = gatewayHost;
        otlpGrpc = "${gatewayHost}:${toString cfg.ports.otlpGrpc}";
        otlpHttp = "http://${gatewayHost}:${toString cfg.ports.otlpHttp}";
      };

      assertions = [
        {
          assertion =
            !cfg.gateway.external.enable
            || ((config.cluster.capabilities.resolved.api-gateway.routing or null) != null);
          message = ''
            otel-collector external gateway (`gateway.external.enable = true`)
            needs `floes.gateway.enable = true`: the HTTPRoute reads
            `config.floes.gateway.exports.internalGatewayName`.
          '';
        }
        {
          assertion = !cfg.exporters.prometheus.enable || (config.floes.prometheus.exports.metrics != null);
          message = ''
            otel-collector prometheus exporter is on but
            `floes.prometheus.enable = false`. Either enable prometheus
            or turn off `exporters.prometheus.enable`.
          '';
        }
        {
          assertion = !cfg.exporters.loki.enable || (config.floes.loki.exports.logIngest != null);
          message = ''
            otel-collector loki exporter is on but
            `floes.loki.enable = false`. Either enable loki or turn off
            `exporters.loki.enable`.
          '';
        }
      ];

      floes.otel-collector.network = {

        declared = true;

        serves.otlp.port = 4317;

        serves.otlpHttp.port = 4318;

        reaches = [

          "loki/api"

          "tempo/otlp"

          "prometheus/api"

        ];

      };

      floes.otel-collector.imagesComplete = true;

      floes.otel-collector.images.collector = {

        repository = "otel/opentelemetry-collector-contrib";

        tag = "0.152.0";

      };

      floes.otel-collector.bundles.otel-collector = {
        helmCharts = (

          optionalAttrs cfg.agent.enable {
            otel-agent = {
              chart = chartRef;
              releaseName = "otel-agent";
              namespace = cfg.namespace;
              createNamespace = true;
              values = agentConfig;
            };
          }

          // optionalAttrs cfg.gateway.enable {
            otel-gateway = {
              chart = chartRef;
              releaseName = "otel-gateway";
              namespace = cfg.namespace;
              createNamespace = true;
              values = gatewayConfig;
            };
          }
        );

        createNamespaces = [ cfg.namespace ];

        resources =
          optionalAttrs
            (cfg.gateway.enable && cfg.gateway.external.enable && cfg.gateway.external.domain != null)
            {
              "otel-gateway-grpcroute" = {
                apiVersion = "gateway.networking.k8s.io/v1";
                kind = "GRPCRoute";
                metadata = {
                  name = "otel-gateway-grpc";
                  namespace = cfg.namespace;
                };
                spec = {
                  parentRefs = [
                    {
                      name =
                        if cfg.gateway.external.tier == "internal" then
                          config.floes.gateway.exports.internalGatewayName
                        else
                          "default-gateway";
                      namespace = "kube-system";

                      sectionName = config.floes.gateway.exports.terminatingListenerName or "https";
                    }
                  ];
                  hostnames = [ cfg.gateway.external.domain ];
                  rules = [
                    {
                      backendRefs = [
                        {
                          name = "otel-gateway-opentelemetry-collector";
                          port = cfg.ports.otlpGrpc;
                        }
                      ];
                    }
                  ];
                };
              };
            }
          //
            optionalAttrs
              (
                cfg.gateway.enable
                && cfg.gateway.external.enable
                && cfg.gateway.external.tls.issuerRef != null
                && cfg.gateway.external.domain != null
              )
              {
                "${cfg.gateway.external.tls.secretName}" = {
                  apiVersion = "cert-manager.io/v1";
                  kind = "Certificate";
                  metadata = {
                    name = cfg.gateway.external.tls.secretName;
                    namespace = cfg.namespace;
                  };
                  spec = {
                    secretName = cfg.gateway.external.tls.secretName;
                    issuerRef = {
                      name = cfg.gateway.external.tls.issuerRef.name;
                      kind = cfg.gateway.external.tls.issuerRef.kind;
                    };
                    dnsNames = [ cfg.gateway.external.domain ];
                  };
                };
              };

        requires = optional (hasCaBundle && caBundle.readyToken != null) caBundle.readyToken;
        provides = [ "otel-collector/gateway/ready" ];

        readyProbe = {
          kind = "condition";
          resource =
            if cfg.gateway.enable then
              "deployment/otel-gateway-opentelemetry-collector"
            else
              "daemonset/otel-agent-opentelemetry-collector";
          namespace = cfg.namespace;
          condition = "Available";
          timeout = "5m";
        };
      };
    }
  );
}

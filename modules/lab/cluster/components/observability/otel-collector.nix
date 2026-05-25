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
    optionals
    ;
  cfg = config.components.otel-collector;

  # Chart reference with fallback
  chartRef = cfg.chart;

  # Determine agent's gateway endpoint
  agentGatewayEndpoint =
    if cfg.agent.gateway.endpoint != null then
      cfg.agent.gateway.endpoint
    else
      "otel-gateway-opentelemetry-collector.${cfg.namespace}.svc.cluster.local:${toString cfg.ports.otlpGrpc}";

  # Build namespace exclusion patterns for filelog receiver
  excludeNamespaces = [ cfg.namespace ] ++ cfg.agent.excludeNamespaces;
  excludePatterns = map (ns: "/var/log/pods/${ns}_*/*/*.log") excludeNamespaces;

  # Build namespace include patterns
  includePatterns =
    if cfg.agent.namespaces == [ ] then
      [ "/var/log/pods/*/*/*.log" ]
    else
      map (ns: "/var/log/pods/${ns}_*/*/*.log") cfg.agent.namespaces;

  # Agent Configuration (DaemonSet)
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

  # Gateway Configuration (Deployment)
  hasCaBundle = cfg.tls.caBundleConfigMap != null;
  caCertPath = "/etc/ssl/certs/lab-ca.crt";

  # TLS config for exporters: use CA bundle when available, insecure otherwise
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
        configMap.name = cfg.tls.caBundleConfigMap;
      }
    ];

    extraVolumeMounts = optionals hasCaBundle [
      {
        name = "ca-bundle";
        mountPath = caCertPath;
        subPath = cfg.tls.caBundleKey;
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
in
{
  # =========================================================================
  # PART 1: High-level options
  # =========================================================================

  options.components.otel-collector = {
    enable = mkEnableOption "OpenTelemetry Collector";

    phase = mkOption {
      type = types.str;
      default = "infrastructure";
      description = "Deployment phase this component belongs to";
    };

    version = mkOption {
      type = types.str;
      default = "0.96.0";
      description = "OpenTelemetry Collector Helm chart version";
    };

    chart = mkOption {
      type = types.package;
      default = cataCharts.otel-collector.chart;
      description = "OpenTelemetry Collector Helm chart derivation";
    };

    namespace = mkOption {
      type = types.str;
      default = "otel";
      description = "Namespace for OpenTelemetry Collector";
    };

    agent = {
      enable = mkEnableOption "OTEL agent (DaemonSet for log collection)";

      namespaces = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Namespaces to collect logs from (empty = all namespaces)";
      };

      excludeNamespaces = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Namespaces to exclude from log collection (otel namespace auto-excluded)";
      };

      gateway = {
        endpoint = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Gateway OTLP endpoint (defaults to local gateway if not set)";
        };
      };

      resources = {
        requests = {
          cpu = mkOption {
            type = types.str;
            default = "50m";
          };
          memory = mkOption {
            type = types.str;
            default = "128Mi";
          };
        };
        limits = {
          cpu = mkOption {
            type = types.str;
            default = "200m";
          };
          memory = mkOption {
            type = types.str;
            default = "256Mi";
          };
        };
      };
    };

    gateway = {
      enable = mkEnableOption "OTEL gateway (Deployment for receiving/forwarding)";

      replicas = mkOption {
        type = types.ints.positive;
        default = 1;
        description = "Number of gateway replicas";
      };

      external = {
        enable = mkEnableOption "Expose gateway externally";

        domain = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Domain for external access";
        };

        tls = {
          issuerRef = mkOption {
            type = types.nullOr (
              types.submodule {
                options = {
                  name = mkOption { type = types.str; };
                  kind = mkOption {
                    type = types.str;
                    default = "ClusterIssuer";
                  };
                };
              }
            );
            default = null;
            description = "cert-manager issuer for the external gateway TLS certificate";
          };
          secretName = mkOption {
            type = types.str;
            default = "otel-gateway-tls";
          };
        };
      };

      resources = {
        requests = {
          cpu = mkOption {
            type = types.str;
            default = "100m";
          };
          memory = mkOption {
            type = types.str;
            default = "256Mi";
          };
        };
        limits = {
          cpu = mkOption {
            type = types.str;
            default = "500m";
          };
          memory = mkOption {
            type = types.str;
            default = "512Mi";
          };
        };
      };
    };

    exporters = {
      otlp = {
        endpoint = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "OTLP gRPC endpoint for traces/metrics/logs (e.g., host:4317)";
        };
      };

      otlphttp = {
        endpoint = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "OTLP HTTP endpoint for traces/metrics/logs (e.g., http://host:4318)";
        };
      };

      prometheus = {
        enable = mkOption {
          type = types.bool;
          default = false;
        };
        endpoint = mkOption {
          type = types.str;
          default = "";
        };
      };

      loki = {
        enable = mkOption {
          type = types.bool;
          default = false;
        };
        endpoint = mkOption {
          type = types.str;
          default = "";
        };
      };
    };

    ports = {
      otlpGrpc = mkOption {
        type = types.port;
        default = 4317;
      };
      otlpHttp = mkOption {
        type = types.port;
        default = 4318;
      };
      prometheus = mkOption {
        type = types.port;
        default = 8889;
      };
    };

    tls = {
      caBundleConfigMap = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "ConfigMap containing the CA bundle for TLS verification on gateway exporters. When null, exporters use tls.insecure=true.";
      };
      caBundleKey = mkOption {
        type = types.str;
        default = "ca.crt";
        description = "Key within the CA bundle ConfigMap";
      };
    };

    ref = mkOption {
      type = types.attrs;
      readOnly = true;
      description = "Computed references for the OpenTelemetry Collector";
    };
  };

  # =========================================================================
  # PART 2: Computed refs and config
  # =========================================================================

  config = lib.mkMerge [
    {
      components.otel-collector.ref =
        let
          gatewayHost = "otel-gateway-opentelemetry-collector.${cfg.namespace}.svc.cluster.local";
        in
        {
          namespace = cfg.namespace;
          gateway = {
            host = gatewayHost;
            otlpGrpc = "${gatewayHost}:${toString cfg.ports.otlpGrpc}";
            otlpHttp = "http://${gatewayHost}:${toString cfg.ports.otlpHttp}";
            otlpGrpcEndpoint = "${gatewayHost}:${toString cfg.ports.otlpGrpc}";
            otlpHttpEndpoint = "http://${gatewayHost}:${toString cfg.ports.otlpHttp}";
          };
          host = gatewayHost;
          otlpGrpc = "${gatewayHost}:${toString cfg.ports.otlpGrpc}";
          otlpHttp = "http://${gatewayHost}:${toString cfg.ports.otlpHttp}";
          otlpGrpcEndpoint = "${gatewayHost}:${toString cfg.ports.otlpGrpc}";
          otlpHttpEndpoint = "http://${gatewayHost}:${toString cfg.ports.otlpHttp}";
        };
    }

    # =========================================================================
    # PART 3: Phase writer
    # =========================================================================

    (mkIf cfg.enable {
      phases.${cfg.phase}.bundles.otel-collector = {
        helmCharts = (
          # Agent release
          optionalAttrs cfg.agent.enable {
            otel-agent = {
              chart = chartRef;
              releaseName = "otel-agent";
              namespace = cfg.namespace;
              createNamespace = true;
              values = agentConfig;
            };
          }
          # Gateway release
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

        # External access for OTEL gateway (gRPC via Gateway API)
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
                      name = "default-gateway";
                      namespace = "kube-system";
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
      };
    })
  ];
}

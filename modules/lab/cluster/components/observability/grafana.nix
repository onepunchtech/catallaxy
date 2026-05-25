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
    optional
    concatStringsSep
    ;
  cfg = config.components.grafana;
  promCfg = config.components.prometheus;
  lokiCfg = config.components.loki;
  tempoCfg = config.components.tempo;

  # Chart reference with fallback
  chartRef = cfg.chart;

  # Auto-discover datasource URLs from co-deployed components
  prometheusUrl =
    if cfg.datasources.prometheus.url != null then
      cfg.datasources.prometheus.url
    else if promCfg.enable then
      promCfg.ref.url
    else
      null;

  lokiUrl =
    if cfg.datasources.loki.url != null then
      cfg.datasources.loki.url
    else if lokiCfg.enable then
      lokiCfg.ref.url
    else
      null;

  tempoUrl =
    if cfg.datasources.tempo.url != null then
      cfg.datasources.tempo.url
    else if tempoCfg.enable then
      tempoCfg.ref.url
    else
      null;

  datasources =
    (optional (prometheusUrl != null) {
      name = "Prometheus";
      type = "prometheus";
      url = prometheusUrl;
      isDefault = true;
      access = "proxy";
    })
    ++ (optional (lokiUrl != null) {
      name = "Loki";
      type = "loki";
      url = lokiUrl;
      access = "proxy";
    })
    ++ (optional (tempoUrl != null) {
      name = "Tempo";
      type = "tempo";
      url = tempoUrl;
      access = "proxy";
    });

  # OIDC configuration for grafana.ini
  oidcConfig = optionalAttrs cfg.oidc.enable {
    "auth.generic_oauth" = {
      enabled = true;
      name = cfg.oidc.name;
      allow_sign_up = cfg.oidc.allowSignUp;
      auto_login = cfg.oidc.autoLogin;
      client_id = cfg.oidc.clientId;
      scopes = concatStringsSep " " cfg.oidc.scopes;
      auth_url = "${cfg.oidc.issuerUrl}/ui/oauth2";
      token_url = "${cfg.oidc.issuerUrl}/oauth2/token";
      api_url = "${cfg.oidc.issuerUrl}/oauth2/openid/${cfg.oidc.clientId}/userinfo";
      use_id_token = true;
      role_attribute_path = cfg.oidc.roleAttributePath;
      groups_attribute_path = "groups";
      skip_org_role_sync = false;
      tls_skip_verify_insecure = cfg.oidc.tlsSkipVerify;
      use_pkce = true;
    }
    // optionalAttrs hasOidcCaCert {
      tls_client_ca = oidcCaCertPath;
    };

    # Disable basic auth when OIDC is enabled (optional)
    auth = {
      disable_login_form = cfg.oidc.autoLogin;
    };
  };

  # Extra environment variables for OIDC client secret
  oidcEnvVars = optional (cfg.oidc.enable && cfg.oidc.clientSecretRef != null) {
    name = "GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET";
    valueFrom = {
      secretKeyRef = {
        name = cfg.oidc.clientSecretRef.name;
        key = cfg.oidc.clientSecretRef.key;
      };
    };
  };

  # Extra volume mounts for CA certificate (supports Secret or ConfigMap)
  hasOidcCaCert =
    cfg.oidc.enable && (cfg.oidc.tlsCaCertSecretRef != null || cfg.oidc.tlsCaBundleConfigMap != null);
  oidcCaCertPath = "/etc/ssl/certs/oidc-ca.crt";

  caCertVolume =
    if cfg.oidc.enable && cfg.oidc.tlsCaCertSecretRef != null then
      [
        {
          name = "oidc-ca-cert";
          secret = {
            secretName = cfg.oidc.tlsCaCertSecretRef.name;
            items = [
              {
                key = cfg.oidc.tlsCaCertSecretRef.key;
                path = "ca.crt";
              }
            ];
          };
        }
      ]
    else if cfg.oidc.enable && cfg.oidc.tlsCaBundleConfigMap != null then
      [
        {
          name = "oidc-ca-cert";
          configMap.name = cfg.oidc.tlsCaBundleConfigMap.name;
        }
      ]
    else
      [ ];

  caCertVolumeMount =
    if hasOidcCaCert then
      [
        {
          name = "oidc-ca-cert";
          mountPath = oidcCaCertPath;
          subPath =
            if cfg.oidc.tlsCaCertSecretRef != null then "ca.crt" else cfg.oidc.tlsCaBundleConfigMap.key;
          readOnly = true;
        }
      ]
    else
      [ ];

in
{
  # =========================================================================
  # PART 1: High-level options
  # =========================================================================

  options.components.grafana = {
    enable = mkEnableOption "Grafana";

    phase = mkOption {
      type = types.str;
      default = "infrastructure";
      description = "Deployment phase this component belongs to";
    };

    version = mkOption {
      type = types.str;
      default = "8.5.2";
      description = "Grafana Helm chart version";
    };

    chart = mkOption {
      type = types.package;
      default = cataCharts.grafana.chart;
      description = "Grafana Helm chart derivation (default: cataCharts.grafana)";
    };

    namespace = mkOption {
      type = types.str;
      default = "grafana";
      description = "Namespace for Grafana";
    };

    domain = mkOption {
      type = types.str;
      default = "grafana.local";
      description = "Domain for Grafana external access";
    };

    adminCredentialsSecret = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Existing secret with admin-user and admin-password keys";
    };

    persistence = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable persistent storage for Grafana";
      };

      size = mkOption {
        type = types.str;
        default = "10Gi";
        description = "PVC size for Grafana data";
      };

      storageClass = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Storage class for PVC";
      };
    };

    # Datasource overrides — when null, auto-discovered from co-deployed components
    datasources = {
      prometheus = {
        url = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Prometheus URL. Auto-configured from components.prometheus.ref when null
            and Prometheus is enabled.
          '';
        };
      };

      loki = {
        url = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Loki URL. Auto-configured from components.loki.ref when null
            and Loki is enabled.
          '';
        };
      };

      tempo = {
        url = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Tempo URL. Auto-configured from components.tempo.ref when null
            and Tempo is enabled.
          '';
        };
      };
    };

    plugins = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Grafana plugins to install (e.g., grafana-tempoexplore-app)";
    };

    sidecar = {
      dashboards = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Enable sidecar for auto-loading dashboards from ConfigMaps";
        };

        searchNamespace = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Namespace(s) to search for dashboard ConfigMaps. null = own namespace, 'ALL' = all namespaces.";
        };
      };
    };

    # OIDC authentication (Kanidm)
    oidc = {
      enable = mkEnableOption "OIDC authentication via Kanidm";

      issuerUrl = mkOption {
        type = types.str;
        default = "";
        description = "OIDC issuer URL (e.g., from Kanidm ref)";
      };

      clientId = mkOption {
        type = types.str;
        default = "grafana";
        description = "OAuth2 client ID";
      };

      clientSecretRef = mkOption {
        type = types.nullOr (
          types.submodule {
            options = {
              name = mkOption {
                type = types.str;
                description = "Secret containing OIDC client secret";
              };
              key = mkOption {
                type = types.str;
                default = "client-secret";
                description = "Key within the secret";
              };
            };
          }
        );
        default = null;
        description = "Reference to Secret containing OIDC client secret";
      };

      scopes = mkOption {
        type = types.listOf types.str;
        default = [
          "openid"
          "email"
          "profile"
          "groups"
        ];
        description = "OIDC scopes to request";
      };

      # Role mapping
      roleAttributePath = mkOption {
        type = types.str;
        default = "contains(groups[*], 'grafana-admins') && 'Admin' || contains(groups[*], 'grafana-editors') && 'Editor' || 'Viewer'";
        description = "JMESPath expression for mapping OIDC claims to Grafana roles";
      };

      # Allow users to be created on first login
      allowSignUp = mkOption {
        type = types.bool;
        default = true;
        description = "Allow OIDC users to be created on first login";
      };

      # Auto-login (skip login page)
      autoLogin = mkOption {
        type = types.bool;
        default = false;
        description = "Automatically redirect to OIDC provider (skip login page)";
      };

      # Provider display name
      name = mkOption {
        type = types.str;
        default = "Kanidm";
        description = "Display name for OIDC provider on login page";
      };

      # TLS verification
      tlsSkipVerify = mkOption {
        type = types.bool;
        default = false;
        description = "Skip TLS certificate verification for OIDC provider";
      };

      # Custom CA certificate
      tlsCaCertSecretRef = mkOption {
        type = types.nullOr (
          types.submodule {
            options = {
              name = mkOption {
                type = types.str;
                description = "Secret containing CA certificate";
              };
              key = mkOption {
                type = types.str;
                default = "ca.crt";
                description = "Key within the secret";
              };
            };
          }
        );
        default = null;
        description = "Reference to Secret containing CA certificate for OIDC provider";
      };

      # CA bundle from ConfigMap (e.g., from trust-manager)
      tlsCaBundleConfigMap = mkOption {
        type = types.nullOr (
          types.submodule {
            options = {
              name = mkOption {
                type = types.str;
                description = "ConfigMap containing CA bundle";
              };
              key = mkOption {
                type = types.str;
                default = "ca.crt";
                description = "Key within the ConfigMap";
              };
            };
          }
        );
        default = null;
        description = "ConfigMap containing CA bundle for OIDC provider (from trust-manager)";
      };
    };

    # TLS configuration
    tls = {
      issuerRef = mkOption {
        type = types.nullOr (
          types.submodule {
            options = {
              name = mkOption {
                type = types.str;
                description = "Issuer or ClusterIssuer name";
              };
              kind = mkOption {
                type = types.str;
                default = "ClusterIssuer";
                description = "Issuer kind";
              };
            };
          }
        );
        default = null;
        description = "cert-manager issuer reference for Grafana TLS certificate";
      };

      secretName = mkOption {
        type = types.str;
        default = "grafana-tls";
        description = "Name of the TLS Secret created by cert-manager";
      };
    };

    replicas = mkOption {
      type = types.ints.positive;
      default = 1;
      description = "Number of Grafana replicas";
    };

    # Gateway API HTTPRoute
    gateway = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable HTTPRoute for external access via Gateway API";
      };

      gatewayRef = mkOption {
        type = types.str;
        default = "default-gateway";
        description = "Name of the Gateway resource to attach to";
      };

      gatewayNamespace = mkOption {
        type = types.nullOr types.str;
        default = "kube-system";
        description = "Namespace of the Gateway resource";
      };
    };

    ref = mkOption {
      type = types.attrs;
      readOnly = true;
      description = "Computed references for Grafana";
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
      components.grafana.ref =
        let
          host = "grafana.${cfg.namespace}.svc.cluster.local";
        in
        {
          inherit host;
          namespace = cfg.namespace;
          port = 80;
          url = "http://${host}:80";
          externalUrl = "https://${cfg.domain}";
          domain = cfg.domain;
        };
    }
    (mkIf cfg.enable {
      # Grafana helm chart
      phases.${cfg.phase}.bundles.grafana = {
        helmCharts.grafana = {
          chart = chartRef;
          releaseName = "grafana";
          namespace = cfg.namespace;
          createNamespace = true;
          values = {
            replicas = cfg.replicas;

            persistence = {
              enabled = cfg.persistence.enable;
              size = cfg.persistence.size;
            }
            // optionalAttrs (cfg.persistence.storageClass != null) {
              storageClassName = cfg.persistence.storageClass;
            };

            plugins = cfg.plugins;

            sidecar.dashboards = {
              enabled = cfg.sidecar.dashboards.enable;
            }
            // optionalAttrs (cfg.sidecar.dashboards.searchNamespace != null) {
              searchNamespace = cfg.sidecar.dashboards.searchNamespace;
            };

            # Grafana configuration
            "grafana.ini" = {
              server = {
                domain = cfg.domain;
                root_url = "https://${cfg.domain}";
              };
            }
            // oidcConfig;
          }
          // optionalAttrs (datasources != [ ]) {
            datasources."datasources.yaml" = {
              apiVersion = 1;
              inherit datasources;
            };
          }
          // optionalAttrs (cfg.adminCredentialsSecret != null) {
            admin.existingSecret = cfg.adminCredentialsSecret;
          }
          // optionalAttrs (oidcEnvVars != [ ]) {
            envFromSecrets = [ ];
            env = oidcEnvVars;
          }
          // optionalAttrs (caCertVolume != [ ]) {
            extraVolumes = caCertVolume;
            extraVolumeMounts = caCertVolumeMount;
          };
        };

        # TLS Certificate for Grafana + HTTPRoute for Gateway API
        resources = lib.mkMerge [
          (mkIf (cfg.tls.issuerRef != null) {
            "${cfg.tls.secretName}" = {
              apiVersion = "cert-manager.io/v1";
              kind = "Certificate";
              metadata = {
                name = cfg.tls.secretName;
                namespace = cfg.namespace;
              };
              spec = {
                secretName = cfg.tls.secretName;
                issuerRef = {
                  name = cfg.tls.issuerRef.name;
                  kind = cfg.tls.issuerRef.kind;
                };
                dnsNames = [ cfg.domain ];
              };
            };
          })
          (mkIf (cfg.gateway.enable && cfg.domain != "") {
            "grafana-httproute" = {
              apiVersion = "gateway.networking.k8s.io/v1";
              kind = "HTTPRoute";
              metadata = {
                name = "grafana";
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
                hostnames = [ cfg.domain ];
                rules = [
                  {
                    matches = [
                      {
                        path = {
                          type = "PathPrefix";
                          value = "/";
                        };
                      }
                    ];
                    backendRefs = [
                      {
                        name = "grafana";
                        port = 80;
                      }
                    ];
                  }
                ];
              };
            };
          })
        ];

        # Namespace creation
        createNamespaces = [ cfg.namespace ];
      };
    })
  ];
}

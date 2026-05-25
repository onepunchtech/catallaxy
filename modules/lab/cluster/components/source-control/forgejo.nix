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
    optionalString
    concatStringsSep
    ;
  cfg = config.components.forgejo;

  # Chart reference with fallback
  chartRef = cfg.chart;

  # HTTPRoute for Gateway API
  httpRouteResource = optionalAttrs (cfg.gateway.enable && cfg.domain != "") {
    forgejo-route = {
      apiVersion = "gateway.networking.k8s.io/v1";
      kind = "HTTPRoute";
      metadata = {
        name = "forgejo";
        namespace = cfg.namespace;
        labels = {
          "app.kubernetes.io/managed-by" = "catallaxy";
        };
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
                name = "forgejo-http";
                port = cfg.server.httpPort;
              }
            ];
          }
        ];
      };
    };
  };

  tlsCertResource = optionalAttrs (cfg.tls.issuerRef != null) {
    forgejo-tls = {
      apiVersion = "cert-manager.io/v1";
      kind = "Certificate";
      metadata = {
        name = cfg.tls.secretName;
        namespace = cfg.namespace;
        labels = {
          "app.kubernetes.io/managed-by" = "catallaxy";
        };
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
  };

  # CA bundle ConfigMap name (from trust-manager)
  caBundleConfigMap = config.components.cert-manager.ref.caBundleConfigMap or "lab-ca-bundle";
  caBundleKey = config.components.cert-manager.ref.caBundleKey or "ca.crt";
  hasCaBundle =
    (config.components.trust-manager.enable or false)
    && (config.components.cert-manager.selfSignedCA.enable or false);

  # OIDC configuration for app.ini
  oidcConfig = optionalAttrs cfg.oidc.enable {
    oauth2_client = {
      REGISTER_EMAIL_CONFIRM = false;
      ENABLE_AUTO_REGISTRATION = true;
      USERNAME = "nickname";
      UPDATE_AVATAR = false;
      ACCOUNT_LINKING = "auto";
    };
  };

  dbSslMode = if cfg.database.ssl then "require" else "disable";
in
{
  options.components.forgejo = {
    enable = mkEnableOption "Forgejo git forge";

    phase = mkOption {
      type = types.str;
      default = "apps";
      description = "Deployment phase this component belongs to";
    };

    version = mkOption {
      type = types.str;
      default = "11.0.14";
      description = "Forgejo version";
    };

    chart = mkOption {
      type = types.package;
      default = cataCharts.forgejo.chart;
      description = "Custom chart derivation";
    };

    namespace = mkOption {
      type = types.str;
      default = "forgejo";
      description = "Namespace for Forgejo";
    };

    domain = mkOption {
      type = types.str;
      description = "Domain for Forgejo external access";
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
      };

      secretName = mkOption {
        type = types.str;
        default = "forgejo-tls";
      };
    };

    database = {
      host = mkOption { type = types.str; };
      port = mkOption {
        type = types.port;
        default = 5432;
      };
      name = mkOption {
        type = types.str;
        default = "forgejo";
      };
      user = mkOption {
        type = types.str;
        default = "forgejo";
      };
      secretRef = mkOption {
        type = types.submodule {
          options = {
            name = mkOption { type = types.str; };
            key = mkOption {
              type = types.str;
              default = "password";
            };
          };
        };
      };
      ssl = mkOption {
        type = types.bool;
        default = false;
      };
    };

    oidc = {
      enable = mkEnableOption "OIDC authentication via Kanidm";
      clientId = mkOption {
        type = types.str;
        default = "forgejo";
      };
      issuerUrl = mkOption {
        type = types.str;
        default = "";
      };
      clientSecretRef = mkOption {
        type = types.nullOr (
          types.submodule {
            options = {
              name = mkOption { type = types.str; };
              key = mkOption {
                type = types.str;
                default = "client-secret";
              };
            };
          }
        );
        default = null;
      };
      scopes = mkOption {
        type = types.listOf types.str;
        default = [
          "openid"
          "email"
          "profile"
          "groups"
        ];
      };
      autoDiscoverUrl = mkOption {
        type = types.str;
        default = "";
      };
      providerName = mkOption {
        type = types.str;
        default = "Kanidm";
      };
      usernameClaim = mkOption {
        type = types.str;
        default = "preferred_username";
      };
      groupsClaim = mkOption {
        type = types.str;
        default = "groups";
      };
      adminGroup = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
    };

    storage = {
      size = mkOption {
        type = types.str;
        default = "10Gi";
      };
      storageClass = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
    };

    server = {
      sshPort = mkOption {
        type = types.port;
        default = 22;
      };
      httpPort = mkOption {
        type = types.port;
        default = 3000;
      };
      lfsEnabled = mkOption {
        type = types.bool;
        default = true;
      };
    };

    admin = {
      existingSecret = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
    };

    replicas = mkOption {
      type = types.ints.positive;
      default = 1;
    };

    gateway = {
      enable = mkOption {
        type = types.bool;
        default = true;
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
    };
  };

  config = lib.mkMerge [
    {
      components.forgejo.ref =
        let
          host = "forgejo-http.${cfg.namespace}.svc.cluster.local";
          sshHost = "forgejo-ssh.${cfg.namespace}.svc.cluster.local";
        in
        {
          inherit host sshHost;
          namespace = cfg.namespace;
          httpPort = cfg.server.httpPort;
          sshPort = cfg.server.sshPort;
          url = "http://${host}:${toString cfg.server.httpPort}";
          externalUrl = "https://${cfg.domain}";
          httpUrl = "https://${cfg.domain}";
          sshUrl = "ssh://git@${cfg.domain}:${toString cfg.server.sshPort}";
          crossClusterUrl = "https://${cfg.domain}";
          domain = cfg.domain;
        };
    }

    (mkIf cfg.enable {
      phases.${cfg.phase}.bundles.forgejo = {
        resources = tlsCertResource // httpRouteResource;

        helmCharts.forgejo = {
          chart = chartRef;
          releaseName = "forgejo";
          namespace = cfg.namespace;
          createNamespace = true;
          values = {
            replicaCount = cfg.replicas;
            image.tag = cfg.version;
            ingress.enabled = false;

            service = {
              http = {
                type = "ClusterIP";
                port = cfg.server.httpPort;
              };
              ssh = {
                type = "ClusterIP";
                port = cfg.server.sshPort;
              };
            };

            persistence = {
              enabled = true;
              size = cfg.storage.size;
            }
            // optionalAttrs (cfg.storage.storageClass != null) {
              storageClass = cfg.storage.storageClass;
            };

            postgresql.enabled = false;
            postgresql-ha.enabled = false;
            redis-cluster.enabled = false;

            gitea = {
              admin = optionalAttrs (cfg.admin.existingSecret != null) {
                existingSecret = cfg.admin.existingSecret;
              };

              config = {
                APP_NAME = "Forgejo";

                server = {
                  DOMAIN = cfg.domain;
                  ROOT_URL = "https://${cfg.domain}/";
                  HTTP_PORT = cfg.server.httpPort;
                  SSH_PORT = cfg.server.sshPort;
                  SSH_DOMAIN = cfg.domain;
                  LFS_START_SERVER = cfg.server.lfsEnabled;
                };

                database = {
                  DB_TYPE = "postgres";
                  HOST = "${cfg.database.host}:${toString cfg.database.port}";
                  NAME = cfg.database.name;
                  USER = cfg.database.user;
                  SSL_MODE = dbSslMode;
                };

                session = {
                  PROVIDER = "db";
                };
                cache = {
                  ADAPTER = "memory";
                };
                queue = {
                  TYPE = "level";
                };
                security = {
                  INSTALL_LOCK = true;
                  SECRET_KEY = "";
                };

                service = {
                  DISABLE_REGISTRATION = cfg.oidc.enable;
                  ALLOW_ONLY_EXTERNAL_REGISTRATION = cfg.oidc.enable;
                };
              }
              // oidcConfig;

              additionalConfigFromEnvs = [
                {
                  name = "FORGEJO__DATABASE__PASSWD";
                  valueFrom.secretKeyRef = {
                    name = cfg.database.secretRef.name;
                    key = cfg.database.secretRef.key;
                  };
                }
              ]
              ++ optional (cfg.oidc.enable && cfg.oidc.clientSecretRef != null) {
                name = "FORGEJO__OAUTH2__JWT_SECRET";
                valueFrom.secretKeyRef = {
                  name = cfg.oidc.clientSecretRef.name;
                  key = cfg.oidc.clientSecretRef.key;
                };
              };
            }
            // optionalAttrs cfg.oidc.enable {
              oauth = [
                (
                  {
                    name = cfg.oidc.providerName;
                    provider = "openidConnect";
                    key = cfg.oidc.clientId;
                    secret = "";
                    autoDiscoverUrl =
                      if cfg.oidc.autoDiscoverUrl != "" then
                        cfg.oidc.autoDiscoverUrl
                      else
                        "${cfg.oidc.issuerUrl}/.well-known/openid-configuration";
                    scopes = concatStringsSep " " cfg.oidc.scopes;
                    groupClaimName = cfg.oidc.groupsClaim;
                  }
                  // optionalAttrs (cfg.oidc.adminGroup != null) {
                    adminGroup = cfg.oidc.adminGroup;
                  }
                  // optionalAttrs (cfg.oidc.clientSecretRef != null) {
                    existingSecret = cfg.oidc.clientSecretRef.name;
                  }
                )
              ];
            };
          }
          // optionalAttrs (cfg.oidc.enable && hasCaBundle) {
            extraVolumes = [
              {
                name = "lab-ca";
                configMap.name = caBundleConfigMap;
              }
            ];
            extraInitVolumeMounts = [
              {
                name = "lab-ca";
                mountPath = "/etc/ssl/certs/lab-ca.crt";
                subPath = caBundleKey;
                readOnly = true;
              }
            ];
            extraVolumeMounts = [
              {
                name = "lab-ca";
                mountPath = "/etc/ssl/certs/lab-ca.crt";
                subPath = caBundleKey;
                readOnly = true;
              }
            ];
          };
        };

        # Namespace created by CNPG cluster in databases phase (when co-located)
      };
    })
  ];
}

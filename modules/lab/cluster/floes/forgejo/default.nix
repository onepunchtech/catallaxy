{
  config,
  lib,
  pkgs,
  cataCharts,
  k8sSpecs,
  k8sHelpers,
  contracts,
  lab,
  ...
}:

let
  inherit ((import ../../../../../lib/floe { inherit lib; })) floeOptions refs;
  cfg = config.floes.forgejo;
in
{
  imports = [
    (floeOptions {
      name = "forgejo";
      version = "11.0.14";
    })
    ./options.nix
    ./bootstrap.nix
  ];

  config = lib.mkIf cfg.enable (
    let
      inherit (lib)
        optionalAttrs
        optional
        optionals
        optionalString
        concatStringsSep
        ;

      exposureResources = k8sHelpers.mkGatewayExposure {
        name = "forgejo";
        namespace = cfg.namespace;
        inherit (cfg) domain gateway tls;
        inherit (config.floes.gateway.exports) internalGatewayName;
        sectionName = config.floes.gateway.exports.terminatingListenerName or "https";
        backend = {
          name = "forgejo-http";
          port = cfg.server.httpPort;
        };
        labels."app.kubernetes.io/managed-by" = "catallaxy";
      };

      caBundle = config.floes.cert-manager.exports.caBundle;
      hasCaBundle = caBundle != null;

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

      oidcSecretNs =
        if
          cfg.oidc.enable && cfg.oidc.clientSecretRef != null && cfg.oidc.clientSecretRef.namespace != null
        then
          cfg.oidc.clientSecretRef.namespace
        else
          cfg.namespace;

      wantOidcWait = cfg.oidc.enable && cfg.oidc.clientSecretRef != null;

      oidcWaitInitContainer = lib.optional wantOidcWait (
        k8sHelpers.wait.mkWaitInitContainer {
          name = "wait-for-oauth2-secret";
          probe = {
            kind = "jsonpath";
            resource = "secret/${cfg.oidc.clientSecretRef.name}";
            namespace = oidcSecretNs;
            jsonpath = "{.data.${cfg.oidc.clientSecretRef.key}}";
            timeout = "10m";
          };
        }
      );

      oidcRbacResources = optionalAttrs wantOidcWait {
        forgejo-oidc-secret-reader-role = {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "Role";
          metadata = {
            name = "forgejo-oidc-secret-reader";
            namespace = oidcSecretNs;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          rules = [
            {
              apiGroups = [ "" ];
              resources = [ "secrets" ];
              resourceNames = [ cfg.oidc.clientSecretRef.name ];

              verbs = [
                "get"
                "list"
                "watch"
              ];
            }
          ];
        };
        forgejo-oidc-secret-reader-rb = {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "RoleBinding";
          metadata = {
            name = "forgejo-oidc-secret-reader";
            namespace = oidcSecretNs;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "Role";
            name = "forgejo-oidc-secret-reader";
          };
          subjects = [
            {
              kind = "ServiceAccount";
              name = "forgejo";
              namespace = cfg.namespace;
            }
          ];
        };
      };
    in
    {

      floes.gateway.internalHostnames =
        if cfg.gateway.enable && cfg.gateway.tier == "internal" && cfg.domain != "" then
          [ cfg.domain ]
        else
          [ ];

      assertions = lib.optional cfg.oidc.enable (
        contracts.oidc.scopeAssertion {
          consumer = "forgejo";
          inherit (cfg.oidc) clientId scopes client;
        }
      );

      floes.forgejo.network = {

        declared = true;

        serves.http.port = 3000;

        serves.ssh.port = 22;

        egress.internet.ports = [
          443
          22
        ];

      };

      floes.forgejo.imagesComplete = true;

      floes.forgejo.images.server = {

        registry = "codeberg.org";

        repository = "forgejo/forgejo";

        tag = "11.0.14-rootless";

      };

      floes.forgejo.bundles.forgejo = {

        owner = {
          bootstrap = "install-target";
          steady = "argocd";
        };

        resources = exposureResources // oidcRbacResources;

        helmCharts.forgejo = {
          chart = cfg.chart;
          releaseName = "forgejo";
          namespace = cfg.namespace;
          createNamespace = true;
          kustomize = lib.optionalAttrs (cfg.oidc.enable && cfg.oidc.clientSecretRef != null) {
            enable = true;
            patches = config.floes.reloader.exports.mkPatches [
              {
                kind = "Deployment";
                name = "forgejo";
                secrets = [ cfg.oidc.clientSecretRef.name ];
              }
            ];
          };
          values = {
            replicaCount = cfg.replicas;
            image.tag = cfg.version;
            ingress.enabled = false;

            strategy = {
              type = "Recreate";
              rollingUpdate = null;
            };

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
          // optionalAttrs wantOidcWait {

            extraInitContainers = oidcWaitInitContainer;
          }
          // optionalAttrs (cfg.oidc.enable && hasCaBundle) {
            extraVolumes = [
              {
                name = "lab-ca";
                configMap.name = caBundle.name;
              }
            ];
            extraInitVolumeMounts = [
              {
                name = "lab-ca";
                mountPath = "/etc/ssl/certs/lab-ca.crt";
                subPath = caBundle.key;
                readOnly = true;
              }
            ];
            extraVolumeMounts = [
              {
                name = "lab-ca";
                mountPath = "/etc/ssl/certs/lab-ca.crt";
                subPath = caBundle.key;
                readOnly = true;
              }
            ];
          };
        };

        requires = [
          "config-reload/ready"
        ]

        ++ optional (cfg.oidc.enable && hasCaBundle && caBundle.readyToken != null) caBundle.readyToken;

        after = [
          "optional:postgres-operator/ready"
        ]
        ++ optional cfg.oidc.enable "identity/provisioning/ready";
        provides = [ "forgejo/git/ready" ];
        readyProbe = {
          kind = "condition";

          resource = "deployment/forgejo";
          namespace = cfg.namespace;
          condition = "Available";
          timeout = "10m";
        };
      };
    }
  );
}

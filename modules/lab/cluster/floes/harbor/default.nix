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
}@__floeModuleArgs:

let
  inherit ((import ../../../../../lib/floe { inherit lib; })) mkFloe refs;
in
(mkFloe {
  name = "harbor";
  version = "1.19.1";
  imports = [ ./options.nix ];

  requires = [
    "gateway"
    "cert-manager"
  ];
  module =
    {
      config,
      lib,
      cataCharts,
      k8sHelpers,
      cfg,
      peers,
      contracts,
      ...
    }:
    let
      inherit (lib)
        optionalAttrs
        optional
        ;
      kappLib = import ../../../../../lib/util/kapp.nix { inherit lib; };

      chartRef = cfg.chart;

      hasCaBundle = cfg.tls.caBundle != null;

      exposureResources = k8sHelpers.mkGatewayExposure {
        name = "harbor";
        namespace = cfg.namespace;
        inherit (cfg) domain gateway tls;
        inherit (config.floes.gateway.exports) internalGatewayName;
        sectionName = config.floes.gateway.exports.terminatingListenerName or "https";
        backend = {
          name = "harbor-nginx";
          port = 80;
        };
        labels."app.kubernetes.io/managed-by" = "catallaxy";
      };

      bootstrapRbac = {
        harbor-admin-sa = {
          apiVersion = "v1";
          kind = "ServiceAccount";
          metadata = {
            name = "harbor-bootstrap";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
        };
        harbor-admin-role = {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "Role";
          metadata = {
            name = "harbor-bootstrap";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          rules = [
            {
              apiGroups = [ "" ];
              resources = [ "secrets" ];
              verbs = [
                "get"
                "create"
                "update"
                "patch"
              ];
            }
          ];
        };
        harbor-admin-rb = {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "RoleBinding";
          metadata = {
            name = "harbor-bootstrap";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "Role";
            name = "harbor-bootstrap";
          };
          subjects = [
            {
              kind = "ServiceAccount";
              name = "harbor-bootstrap";
              namespace = cfg.namespace;
            }
          ];
        };
      };

      # Was a heredoc with a Nix interpolation per field. The client secret is
      # deliberately absent: it lives in a Secret, and the script merges it in
      # with jq once it has read it.
      # One object per robot. This was a generated shell line per robot, which
      # is what kept the script in a Nix string.
      robotSpecs = lib.mapAttrsToList (name: robot: {
        inherit name;
        inherit (robot) secretName;
        payload = {
          inherit name;
          inherit (robot)
            duration
            description
            level
            permissions
            ;
          disable = false;
        };
      }) cfg.robots;

      oidcConfig = {
        auth_mode = "oidc_auth";
        oidc_name = cfg.oidc.providerName;
        oidc_endpoint = cfg.oidc.issuerUrl;
        oidc_client_id = cfg.oidc.clientId;
        oidc_scope = lib.concatStringsSep "," cfg.oidc.scopes;
        oidc_groups_claim = cfg.oidc.groupsClaim;
        oidc_admin_group =
          if cfg.oidc.adminGroup != "" then cfg.oidc.adminGroup + cfg.oidc.groupSuffix else "";
        oidc_user_claim = cfg.oidc.userClaim;
        oidc_auto_onboard = cfg.oidc.autoOnboard;
        oidc_verify_cert = cfg.oidc.verifyCert;
      };

      oidcClientSecretNs =
        if cfg.oidc.clientSecretRef != null then
          (
            if cfg.oidc.clientSecretRef.namespace != null then
              cfg.oidc.clientSecretRef.namespace
            else
              cfg.namespace
          )
        else
          null;

      oidcRbacResource =
        optionalAttrs
          (cfg.oidc.enable && cfg.oidc.clientSecretRef != null && oidcClientSecretNs != cfg.namespace)
          {
            harbor-oidc-secret-reader-role = {
              apiVersion = "rbac.authorization.k8s.io/v1";
              kind = "Role";
              metadata = {
                name = "harbor-oidc-secret-reader";
                namespace = oidcClientSecretNs;
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
            harbor-oidc-secret-reader-rb = {
              apiVersion = "rbac.authorization.k8s.io/v1";
              kind = "RoleBinding";
              metadata = {
                name = "harbor-oidc-secret-reader";
                namespace = oidcClientSecretNs;
                labels."app.kubernetes.io/managed-by" = "catallaxy";
              };
              roleRef = {
                apiGroup = "rbac.authorization.k8s.io";
                kind = "Role";
                name = "harbor-oidc-secret-reader";
              };
              subjects = [
                {
                  kind = "ServiceAccount";
                  name = "harbor-bootstrap";
                  namespace = cfg.namespace;
                }
              ];
            };
          };

      oidcBootstrapResource = optionalAttrs cfg.oidc.enable {
        harbor-oidc-bootstrap = {
          apiVersion = "batch/v1";
          kind = "Job";
          metadata = {
            name = "harbor-oidc-bootstrap";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
            annotations."kapp.k14s.io/update-strategy" = "fallback-on-replace";
          };
          spec = {
            backoffLimit = 10;
            template = {
              metadata.labels.app = "harbor-oidc-bootstrap";
              spec = {
                serviceAccountName = "harbor-bootstrap";
                restartPolicy = "OnFailure";

                initContainers = lib.optional (cfg.oidc.clientSecretRef != null) (
                  k8sHelpers.wait.mkWaitInitContainer {
                    name = "wait-for-oauth2-secret";
                    probe = config.floes.kanidm.exports.oauth2Clients.${cfg.oidc.clientId}.readyProbe;
                  }
                );
                containers = [
                  {
                    name = "configure-oidc";
                    image = cfg.images.bootstrap.ref;
                    env = [
                      {
                        name = "HARBOR_URL";
                        value = "http://harbor-core.${cfg.namespace}.svc.cluster.local";
                      }
                      {
                        name = "ADMIN_PASSWORD";
                        valueFrom.secretKeyRef = {
                          name = cfg.adminPasswordSecret;
                          key = "HARBOR_ADMIN_PASSWORD";
                        };
                      }
                      {
                        name = "OIDC_CONFIG_JSON";
                        value = builtins.toJSON oidcConfig;
                      }
                    ]
                    ++ lib.optionals (cfg.oidc.clientSecretRef != null) [
                      {
                        name = "OIDC_CLIENT_SECRET_NS";
                        value = oidcClientSecretNs;
                      }
                      {
                        name = "OIDC_CLIENT_SECRET_NAME";
                        value = cfg.oidc.clientSecretRef.name;
                      }
                      {
                        name = "OIDC_CLIENT_SECRET_KEY";
                        value = cfg.oidc.clientSecretRef.key;
                      }
                    ];
                    command = [
                      "bash"
                      "-c"
                    ];
                    args = [
                      (builtins.readFile ./scripts/oidc.sh)
                    ];
                    volumeMounts = optional hasCaBundle {
                      name = "lab-ca";
                      mountPath = "/etc/ssl/certs/lab-ca.crt";
                      subPath = cfg.tls.caBundle.key;
                      readOnly = true;
                    };
                  }
                ];
                volumes = optional hasCaBundle {
                  name = "lab-ca";
                  configMap.name = cfg.tls.caBundle.name;
                };
              };
            };
          };
        };
      };

      robotBootstrapResource = optionalAttrs (cfg.robots != { }) {
        harbor-robot-bootstrap = {
          apiVersion = "batch/v1";
          kind = "Job";
          metadata = {
            name = "harbor-robot-bootstrap";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
            annotations."kapp.k14s.io/update-strategy" = "fallback-on-replace";
          };
          spec = {
            backoffLimit = 10;
            template = {
              metadata.labels.app = "harbor-robot-bootstrap";
              spec = {
                serviceAccountName = "harbor-bootstrap";
                restartPolicy = "OnFailure";
                containers = [
                  {
                    name = "create-robots";
                    image = cfg.images.bootstrap.ref;
                    env = [
                      {
                        name = "HARBOR_URL";
                        value = "http://harbor-core.${cfg.namespace}.svc.cluster.local";
                      }
                      {
                        name = "HARBOR_EXTERNAL_HOST";
                        value = cfg.domain;
                      }
                      {
                        name = "ADMIN_PASSWORD";
                        valueFrom.secretKeyRef = {
                          name = cfg.adminPasswordSecret;
                          key = "HARBOR_ADMIN_PASSWORD";
                        };
                      }
                      {
                        name = "NS";
                        value = cfg.namespace;
                      }
                      {
                        name = "ROBOTS_JSON";
                        value = builtins.toJSON robotSpecs;
                      }
                    ];
                    command = [
                      "bash"
                      "-c"
                    ];
                    args = [
                      (builtins.readFile ./scripts/robots.sh)
                    ];
                    volumeMounts = optional hasCaBundle {
                      name = "lab-ca";
                      mountPath = "/etc/ssl/certs/lab-ca.crt";
                      subPath = cfg.tls.caBundle.key;
                      readOnly = true;
                    };
                  }
                ];
                volumes = optional hasCaBundle {
                  name = "lab-ca";
                  configMap.name = cfg.tls.caBundle.name;
                };
              };
            };
          };
        };
      };

      projectBootstrapResource =
        let
          roleId = {
            projectAdmin = 1;
            developer = 2;
            guest = 3;
            maintainer = 4;
            limitedGuest = 5;
          };
          entityTypeId = {
            user = 1;
            group = 2;
          };

          boolStr = b: if b then "true" else "false";

          projectPayload =
            name: p:
            {
              project_name = name;
              metadata = {
                public = boolStr p.public;
                auto_scan = boolStr p.autoScan;
                prevent_vul = boolStr p.preventVuln;
                reuse_sys_cve_allowlist = boolStr p.reuseSysCveAllowlist;
              }
              // optionalAttrs (p.severity != null) {
                severity = p.severity;
              };
            }
            // optionalAttrs (p.storageQuota >= 0) {
              storage_limit = p.storageQuota;
            };

          registryName = projectName: "proxy-cache-${projectName}";

          registryPayload =
            projectName: pc:
            {
              name = registryName projectName;
              type = pc.registryType;
              url = pc.endpointUrl;
              insecure = false;
              description = "Proxy cache for ${projectName}";
            }
            // optionalAttrs (pc.credentialUsername != null) {
              credential = {
                type = "basic";
                access_key = pc.credentialUsername;
                access_secret = "<<PASSWORD>>";
              };
            };

          retentionPayload = p: {
            algorithm = "or";
            rules = p.retention.rules;
            trigger = {
              kind = "Schedule";
              references = { };
              settings.cron = p.retention.schedule;
            };
            scope = {
              level = "project";
              ref = 0;
            };
          };

          cveAllowlistPayload = p: {
            items = map (cve: { cve_id = cve; }) p.cveAllowlist;
            expires_at = null;
          };

          # One object per project, replacing a function that generated a shell
          # program per project. The script iterates it; nothing about a
          # project is expressed as generated bash any more.
          projectSpecs = lib.mapAttrsToList (name: p: {
            inherit name;
            create = projectPayload name p;

            registry =
              if p.proxyCache == null then
                null
              else
                {
                  name = registryName name;
                  payload = registryPayload name p.proxyCache;
                  credSecret =
                    if p.proxyCache.credentialPasswordRef == null then
                      null
                    else
                      { inherit (p.proxyCache.credentialPasswordRef) name key; };
                };

            inherit (p) storageQuota;

            members = lib.mapAttrsToList (mname: m: {
              entity = mname + lib.optionalString (m.entityType == "group") cfg.oidc.groupSuffix;
              entityType = entityTypeId.${m.entityType};
              roleId = roleId.${m.role};
            }) p.members;

            retention = if p.retention == null then null else retentionPayload p;
            immutableRules = p.immutableTagRules;
            cveAllowlist = if p.cveAllowlist == [ ] then null else cveAllowlistPayload p;
          }) cfg.projects;
        in
        optionalAttrs (cfg.projects != { }) {
          harbor-project-bootstrap = {
            apiVersion = "batch/v1";
            kind = "Job";
            metadata = {
              name = "harbor-project-bootstrap";
              namespace = cfg.namespace;
              labels."app.kubernetes.io/managed-by" = "catallaxy";
              annotations."kapp.k14s.io/update-strategy" = "fallback-on-replace";
            };
            spec = {
              backoffLimit = 10;
              template = {
                metadata.labels.app = "harbor-project-bootstrap";
                spec = {
                  serviceAccountName = "harbor-bootstrap";
                  restartPolicy = "OnFailure";
                  containers = [
                    {
                      name = "create-projects";
                      image = cfg.images.bootstrap.ref;
                      env = [
                        {
                          name = "HARBOR_URL";
                          value = "http://harbor-core.${cfg.namespace}.svc.cluster.local";
                        }
                        {
                          name = "ADMIN_PASSWORD";
                          valueFrom.secretKeyRef = {
                            name = cfg.adminPasswordSecret;
                            key = "HARBOR_ADMIN_PASSWORD";
                          };
                        }
                        {
                          name = "NS";
                          value = cfg.namespace;
                        }
                        {
                          name = "PROJECTS_JSON";
                          value = builtins.toJSON projectSpecs;
                        }
                      ];
                      command = [
                        "bash"
                        "-c"
                      ];
                      args = [
                        (builtins.readFile ./scripts/projects.sh)
                      ];
                      volumeMounts = optional hasCaBundle {
                        name = "lab-ca";
                        mountPath = "/etc/ssl/certs/lab-ca.crt";
                        subPath = cfg.tls.caBundle.key;
                        readOnly = true;
                      };
                    }
                  ];
                  volumes = optional hasCaBundle {
                    name = "lab-ca";
                    configMap.name = cfg.tls.caBundle.name;
                  };
                };
              };
            };
          };
        };

      harborValues = {
        expose = {
          type = "clusterIP";
          tls.enabled = false;
          clusterIP.name = "harbor-nginx";
        };
        externalURL = "https://${cfg.domain}";
        existingSecretAdminPassword = cfg.adminPasswordSecret;
        existingSecretAdminPasswordKey = "HARBOR_ADMIN_PASSWORD";
        existingSecretSecretKey = cfg.secretKeySecret;
      }

      // optionalAttrs (cfg.tls.caBundleSecret != null) {
        caBundleSecretName = cfg.tls.caBundleSecret.name;
      }
      // {
        persistence =
          let
            scAttrs = optionalAttrs (cfg.storage.storageClass != null) {
              storageClass = cfg.storage.storageClass;
            };
          in
          {
            enabled = true;
            persistentVolumeClaim = {
              registry = {
                size = cfg.storage.registry.size;
              }
              // scAttrs;
              jobservice.jobLog = {
                size = cfg.storage.jobLog.size;
              }
              // scAttrs;
              database = {
                size = cfg.storage.database.size;
              }
              // scAttrs;
              redis = {
                size = cfg.storage.redis.size;
              }
              // scAttrs;
              trivy = {
                size = cfg.storage.trivy.size;
              }
              // scAttrs;
            };
          };
        trivy.enabled = cfg.trivy.enable;
        internalTLS.enabled = false;
        database.type = "internal";
        redis.type = "internal";
        metrics.enabled = cfg.metrics.enable;
      };

    in
    {
      cluster.registryDomains = lib.optional (cfg.domain != "") cfg.domain;

      assertions = [
        {
          assertion = !cfg.oidc.enable || cfg.oidc.client != null;
          message = "harbor OIDC login is enabled but no identity provider publishes an OAuth2 client named \"${cfg.oidc.clientId}\".";
        }
      ]
      ++ lib.optional cfg.oidc.enable (
        contracts.oidc.scopeAssertion {
          consumer = "harbor";
          inherit (cfg.oidc) clientId scopes client;
        }
      );

      floes.gateway.internalHostnames =
        if cfg.gateway.enable && cfg.gateway.tier == "internal" && cfg.domain != "" then
          [ cfg.domain ]
        else
          [ ];

      floes.harbor.images.bootstrap = {
        repository = "alpine/k8s";
        tag = "1.32.4";
      };

      secrets.generate = {
        ${cfg.adminPasswordSecret} = {
          inherit (cfg) namespace;
          key = "HARBOR_ADMIN_PASSWORD";
          length = 24;
        };
        ${cfg.secretKeySecret} = {
          inherit (cfg) namespace;
          key = "secretKey";
          length = 16;
        };
      };

      floes.harbor.network = {

        declared = true;

        serves.core.port = 80;

        serves.registry.port = 5000;

        egress.internet.ports = [ 443 ];

      };

      floes.harbor.imagesComplete = true;

      floes.harbor.images.core = {

        repository = "goharbor/harbor-core";

        tag = "v2.15.1";

      };

      floes.harbor.images.database = {

        repository = "goharbor/harbor-db";

        tag = "v2.15.1";

      };

      floes.harbor.images.jobservice = {

        repository = "goharbor/harbor-jobservice";

        tag = "v2.15.1";

      };

      floes.harbor.images.portal = {

        repository = "goharbor/harbor-portal";

        tag = "v2.15.1";

      };

      floes.harbor.images.registryctl = {

        repository = "goharbor/harbor-registryctl";

        tag = "v2.15.1";

      };

      floes.harbor.images.nginx = {

        repository = "goharbor/nginx-photon";

        tag = "v2.15.1";

      };

      floes.harbor.images.redis = {

        repository = "goharbor/redis-photon";

        tag = "v2.15.1";

      };

      floes.harbor.images.registry = {

        repository = "goharbor/registry-photon";

        tag = "v2.15.1";

      };

      bundles.harbor = {
        resources =
          exposureResources
          // bootstrapRbac
          // oidcRbacResource
          // oidcBootstrapResource
          // robotBootstrapResource
          // projectBootstrapResource;

        helmCharts.harbor = {
          chart = chartRef;
          releaseName = "harbor";
          namespace = cfg.namespace;
          createNamespace = true;

          kustomize = {
            enable = true;
            patches = kappLib.mkPreserveRuntimePatches [
              {
                kind = "Secret";
                name = "harbor-registryctl";
              }
            ];
          };
          values = harborValues;
        };

        createNamespaces = [ cfg.namespace ];

        # Both Secrets reach harbor as Helm values, and the auto-edge that
        # would find them walks rendered resources, so it sees neither. It
        # does reach the admin one through the bootstrap Jobs' secretKeyRef,
        # but only when OIDC or robots or projects are configured, so both are
        # named here.
        requires = [
          "secret:${cfg.namespace}/${cfg.adminPasswordSecret}"
          "secret:${cfg.namespace}/${cfg.secretKeySecret}"
        ]
        ++ refs.needs peers.cert-manager.issuance "webhookReady"
        ++ refs.needs peers.gateway.routing "publicReady"
        ++ optional (hasCaBundle && cfg.tls.caBundle.readyToken != null) cfg.tls.caBundle.readyToken;
        provides = [ "harbor/registry/ready" ];
        readyProbe = {
          kind = "condition";
          resource = "deployment/harbor-core";
          namespace = cfg.namespace;
          condition = "Available";
          timeout = "10m";
        };
      };
    };
})
  __floeModuleArgs

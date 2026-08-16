{
  config,
  lib,
  pkgs,
  cataCharts,
  k8sSpecs,
  k8sHelpers,
  lab,
  ...
}@__floeModuleArgs:

let
  inherit ((import ../../../../../lib/floe { inherit lib; })) mkFloe refs;
  planTokens = import ../../../../../lib/plan-tokens.nix { inherit lib; };
  verifyTypes = import ../../../verify-types.nix { inherit lib; };
in
(mkFloe {
  name = "argocd";
  version = "v2.13.0";
  imports = [ ./options.nix ];

  requires = [
    "gateway"
    "reloader"
  ];
  module =
    {
      config,
      lib,
      cfg,
      k8sHelpers,
      peers,
      ...
    }:
    let
      inherit (lib)
        mapAttrsToList
        filterAttrs
        optional
        optionalAttrs
        optionals
        ;
      kappLib = import ../../../../../lib/util/kapp.nix { inherit lib; };
      catalLib = import ../../../../../lib/util/idempotent-job.nix { inherit lib; };
      driftLib = import ../../../../../lib/eval/drift.nix { inherit lib; };

      driftOut =
        config.cluster.drift.out or {
          entries = [ ];
          aggregateManagers = [ ];
        };
      driftCustomizations = driftLib.toArgocdResourceCustomizations {
        inherit (driftOut) entries aggregateManagers;
      };

      redisSecretInitName = "argocd-redis-secret-init";
      redisSecretInitSa = {
        apiVersion = "v1";
        kind = "ServiceAccount";
        metadata = {
          name = redisSecretInitName;
          namespace = cfg.namespace;
          labels."app.kubernetes.io/managed-by" = "catallaxy";
        };
      };
      redisSecretInitRole = {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "Role";
        metadata = {
          name = redisSecretInitName;
          namespace = cfg.namespace;
          labels."app.kubernetes.io/managed-by" = "catallaxy";
        };
        rules = [
          {
            apiGroups = [ "" ];
            resources = [ "secrets" ];
            resourceNames = [ "argocd-redis" ];
            verbs = [ "get" ];
          }
          {
            apiGroups = [ "" ];
            resources = [ "secrets" ];
            verbs = [ "create" ];
          }
        ];
      };
      redisSecretInitRb = {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "RoleBinding";
        metadata = {
          name = redisSecretInitName;
          namespace = cfg.namespace;
          labels."app.kubernetes.io/managed-by" = "catallaxy";
        };
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "Role";
          name = redisSecretInitName;
        };
        subjects = [
          {
            kind = "ServiceAccount";
            name = redisSecretInitName;
            namespace = cfg.namespace;
          }
        ];
      };
      # Not a secrets.generate entry, unlike harbor's and netbird's. The
      # randomness is inside `argocd admin redis-initial-password`, which also
      # writes the value in the shape argocd's own controllers read back. A
      # Password generator produces a string; it does not produce that.
      redisSecretInitJob = catalLib.mkIdempotentJob {
        name = redisSecretInitName;
        namespace = cfg.namespace;
        contentInputs = {
          image = cfg.images.redis-secret-init.ref;
          command = "argocd admin redis-initial-password";
        };
        podSpec = {
          serviceAccountName = redisSecretInitName;
          restartPolicy = "OnFailure";
          containers = [
            {
              name = "secret-init";
              image = cfg.images.redis-secret-init.ref;
              command = [
                "argocd"
                "admin"
                "redis-initial-password"
              ];
            }
          ];
        };
      };

      oauth2SecretName = "${cfg.oidc.clientId}-kanidm-oauth2-credentials";

      reposWithCreds = filterAttrs (
        _: repo:
        repo.usernameSecretRef != null
        || repo.passwordSecretRef != null
        || repo.sshPrivateKeySecretRef != null
      ) cfg.repositories;

      repoSecretResources = lib.listToAttrs (
        mapAttrsToList (name: repo: {
          name = "argocd-repo-${name}";
          value = {
            apiVersion = "v1";
            kind = "Secret";
            metadata = {
              name = "argocd-repo-${name}";
              namespace = cfg.namespace;
              labels = {
                "argocd.argoproj.io/secret-type" = "repository";
              };
            };
            type = "Opaque";
            stringData = {
              type = repo.type;
              url = repo.url;
              project = repo.project;
            }
            // optionalAttrs repo.insecure {
              insecure = "true";
            }
            // optionalAttrs repo.enableLfs {
              enableLfs = "true";
            };
          };
        }) cfg.repositories
      );

      hasOidcCaBundle = cfg.oidc.caBundle != null;
      oidcCaCertPath = "/etc/ssl/certs/oidc-ca.crt";

      oidcConfig = optionalAttrs cfg.oidc.enable {
        configs = {
          cm = {
            "dex.config" = builtins.toJSON {
              connectors = [
                {
                  type = "oidc";
                  id = "kanidm";
                  name = cfg.oidc.name;
                  config = {
                    issuer = cfg.oidc.issuerUrl;
                    clientID = cfg.oidc.clientId;
                    clientSecret = "$" + "${cfg.oidc.clientId}-kanidm-oauth2-credentials:CLIENT_SECRET";
                    insecureEnableGroups = true;
                    scopes = [
                      "openid"
                      "email"
                      "profile"
                      "groups"
                    ];
                  }
                  // (
                    if hasOidcCaBundle then
                      {
                        rootCAs = [ oidcCaCertPath ];
                        insecureSkipVerify = false;
                      }
                    else
                      { insecureSkipVerify = true; }
                  );
                }
              ];
            };
          }
          // optionalAttrs (cfg.domain != "") {
            url = "https://${cfg.domain}";
          };
        };

        dex = {
          initContainers = optionals cfg.oidc.enable [
            (k8sHelpers.wait.mkWaitInitContainer {
              name = "wait-for-oauth2-secret";
              probe = config.floes.kanidm.exports.oauth2Clients.${cfg.oidc.clientId}.readyProbe;
            })
            (k8sHelpers.wait.mkWaitInitContainer {
              name = "wait-for-kanidm-dns";
              probe = {
                kind = "dns";
                hostname = config.floes.kanidm.exports.externalHost;
                timeout = "10m";
                interval = "10s";
              };
            })
            (k8sHelpers.wait.mkWaitInitContainer {
              name = "wait-for-kanidm-tcp";
              probe = {
                kind = "tcp";

                host = config.floes.kanidm.exports.externalHost;
                port = config.floes.kanidm.exports.externalPort;
                timeout = "10m";
                interval = "10s";
              };
            })
          ];
        }
        // optionalAttrs hasOidcCaBundle {
          volumeMounts = [
            {
              name = "oidc-ca-bundle";
              mountPath = oidcCaCertPath;
              subPath = cfg.oidc.caBundle.key;
              readOnly = true;
            }
          ];
          volumes = [
            {
              name = "oidc-ca-bundle";
              configMap.name = cfg.oidc.caBundle.name;
            }
          ];
        };
      };
    in
    {
      steps =
        let
          clusterName = config.cluster.name;
          t = planTokens;
          installed = {
            provides = [
              (t.cluster clusterName).argocdInstalled
              (t.cluster clusterName).gitReady
              t.lab.gitReady
            ];
            after = [ (t.needs (t.cluster clusterName).reachable) ];
          };
          bootstrapStep =
            {
              "kubectl-ssa" = installed // {
                kind = "bootstrap-argocd-kubectl-ssa";
                params = {
                  target = clusterName;
                  manifestRoot = "bootstrap/${clusterName}";
                  fieldManager = "catallaxy-bootstrap";
                  namespace = cfg.namespace;
                  waitTimeoutSeconds = 600;
                };
                description = "Install argocd + install-target set on '${clusterName}' via kubectl SSA";
              };
              "helm" = installed // {
                kind = "bootstrap-argocd-helm";
                params = {
                  target = clusterName;
                  valuesPath = "bootstrap/${clusterName}/argocd-values.yaml";
                  chartRef = "argo/argo-cd";
                  releaseName = "argocd";
                  namespace = cfg.namespace;
                  waitTimeoutSeconds = 300;
                };
                description = "Install argocd on '${clusterName}' via helm";
              };
              "none" = installed // {
                kind = "verify-argocd-reachable";
                params = {
                  target = clusterName;
                  namespace = cfg.namespace;
                };
                description = "Verify argocd is already installed on '${clusterName}'";
              };
            }
            .${lab.cd.bootstrap};
        in
        {
          bootstrap-argocd = bootstrapStep;
        }
        // lib.optionalAttrs (lab.cd.git.repo != "") {
          apply-root = {
            kind = "apply-root-application";
            after = [
              (t.needs t.lab.manifestsPushed)
              (t.wants (t.cluster clusterName).forgejoBootstrapped)
            ];
            provides = [ (t.cluster clusterName).gitopsStarted ];
            params = {
              target = clusterName;
              manifestPath = "manifests/${clusterName}/root-app.yaml";
            };
            description = "Apply argocd root Application on '${clusterName}' (starts gitops sync)";
          };
        };

      floes.argocd.verify.applications-converged = {
        description = "Every argocd Application reached Synced and Healthy";
        timeout = "10m";
        reject = [
          {
            apiVersion = "argoproj.io/v1alpha1";
            kind = "Application";
            metadata.namespace = cfg.namespace;
            ${
              verifyTypes.fieldIsNot {
                field = "status.sync.status";
                value = "Synced";
              }
            } =
              true;
          }
          {
            apiVersion = "argoproj.io/v1alpha1";
            kind = "Application";
            metadata.namespace = cfg.namespace;
            ${
              verifyTypes.fieldIsNot {
                field = "status.health.status";
                value = "Healthy";
              }
            } =
              true;
          }
        ];
      };

      assertions = [
        {
          assertion = !cfg.oidc.enable || (peers.kanidm.identity != null);
          message = "argocd OIDC login requires floes.kanidm to be enabled (produces the OAuth2 client Secret via kaniop).";
        }
        {
          assertion = cfg.tls.issuerRef == null || (peers.cert-manager.issuance != null);
          message = "argocd tls.issuerRef is set but floes.cert-manager is disabled; the Certificate CR will not reconcile.";
        }
      ];

      floes.gateway.internalHostnames =
        if cfg.gateway.enable && cfg.gateway.tier == "internal" && cfg.domain != "" then
          [ cfg.domain ]
        else
          [ ];

      floes.argocd.images.redis-secret-init = {
        registry = "quay.io";
        repository = "argoproj/argocd";
        tag = "v3.0.1";
      };

      floes.argocd.network = {

        declared = true;

        serves.http.port = 80;

        egress.internet.ports = [
          443
          22
        ];

      };

      floes.argocd.imagesComplete = true;

      floes.argocd.images.dex = {

        registry = "ghcr.io";

        repository = "dexidp/dex";

        tag = "v2.42.1";

      };

      floes.argocd.images.redis = {

        registry = "public.ecr.aws";

        repository = "docker/library/redis";

        tag = "7.2.8-alpine";

      };

      bundles.argocd = {

        owner = {
          bootstrap = "install-target";
          steady = "argocd";
        };
        helmCharts.argocd = {
          chart = cfg.chart;
          releaseName = "argocd";
          namespace = cfg.namespace;
          createNamespace = true;

          kustomize = {
            enable = true;
            patches =
              kappLib.mkPreserveRuntimePatches [
                {
                  kind = "Secret";
                  name = "argocd-secret";
                }
                {
                  kind = "Secret";
                  name = "argocd-notifications-secret";
                }
              ]

              ++ lib.optionals cfg.oidc.enable (
                config.floes.reloader.exports.mkPatches [
                  {
                    kind = "Deployment";
                    name = "argocd-dex-server";
                    secrets = [ oauth2SecretName ];
                  }
                ]
              )

              ++ config.floes.reloader.exports.mkPatches [
                {
                  kind = "Deployment";
                  name = "argocd-server";
                  secrets = [ "argocd-redis" ];
                }
                {
                  kind = "Deployment";
                  name = "argocd-repo-server";
                  secrets = [ "argocd-redis" ];
                }
                {
                  kind = "StatefulSet";
                  name = "argocd-application-controller";
                  secrets = [ "argocd-redis" ];
                }
                {
                  kind = "Deployment";
                  name = "argocd-notifications-controller";
                  secrets = [ "argocd-redis" ];
                }
                {
                  kind = "Deployment";
                  name = "argocd-applicationset-controller";
                  secrets = [ "argocd-redis" ];
                }
              ];
          };

          values =
            lib.foldl' lib.recursiveUpdate
              {
                server.extraArgs = optionals (!cfg.ha) [ "--insecure" ];
                controller.replicas = if cfg.ha then 2 else 1;
                repoServer.replicas = if cfg.ha then 2 else 1;
                applicationSet.replicas = if cfg.ha then 2 else 1;
                configs.secret.createSecret = true;

                redisSecretInit.enabled = false;

                configs.params = {
                  "reposerver.max.combined.directory.manifests.size" = "50M";

                  "controller.diff.server.side" = "true";
                };

                configs.cm."resource.customizations.ignoreDifferences.all" = ''
                  jsonPointers:
                  - /metadata/labels/kapp.k14s.io~1app
                  - /metadata/labels/kapp.k14s.io~1association
                  - /metadata/annotations/kapp.k14s.io~1identity
                  - /metadata/annotations/kapp.k14s.io~1original
                  - /metadata/annotations/kapp.k14s.io~1original-diff-md5
                  - /spec/selector/kapp.k14s.io~1app
                  - /spec/template/metadata/annotations/reloader.stakater.com~1last-reloaded-from
                '';

              }
              [

                { configs.cm = driftCustomizations; }
                oidcConfig
                (optionalAttrs
                  (cfg.rbac.groupBindings != { } || cfg.rbac.defaultRole != "" || cfg.rbac.extraPolicy != "")
                  {
                    configs.rbac = {
                      "policy.default" = cfg.rbac.defaultRole;
                      "policy.csv" =
                        let
                          bindings = lib.concatStringsSep "\n" (
                            lib.mapAttrsToList (group: role: "g, ${group}, ${role}") cfg.rbac.groupBindings
                          );
                        in
                        bindings + lib.optionalString (cfg.rbac.extraPolicy != "") ("\n" + cfg.rbac.extraPolicy);
                      scopes = cfg.rbac.scopes;
                    };
                  }
                )
              ];
        };

        resources =
          repoSecretResources
          // {
            "${redisSecretInitName}-sa" = redisSecretInitSa;
            "${redisSecretInitName}-role" = redisSecretInitRole;
            "${redisSecretInitName}-rb" = redisSecretInitRb;
          }
          // redisSecretInitJob.resources
          // k8sHelpers.mkGatewayExposure {
            name = "argocd";
            routeName = "argocd-httproute";
            namespace = cfg.namespace;
            inherit (cfg) domain gateway tls;
            inherit (config.floes.gateway.exports) internalGatewayName;
            sectionName = config.floes.gateway.exports.terminatingListenerName or "https";
            backend = {
              name = "argocd-server";
              port = 80;
            };
          };

        createNamespaces = [ cfg.namespace ];

        requires =
          refs.needs peers.cert-manager.issuance "webhookReady"
          ++ refs.needs peers.gateway.routing "publicReady"
          ++ refs.needs peers.reloader.watching "ready"

          ++ optional (hasOidcCaBundle && cfg.oidc.caBundle.readyToken != null) cfg.oidc.caBundle.readyToken;

        after =
          refs.orderAfter peers.kanidm.identity "instanceReady"

          ++ optionals cfg.oidc.enable (refs.orderAfter peers.kanidm.identity "provisioningReady");
        provides = [ "argocd/server/ready" ];
        readyProbe = {
          kind = "condition";
          resource = "deployment/argocd-server";
          namespace = cfg.namespace;
          condition = "Available";
          timeout = "10m";
        };
      };
    };
})
  __floeModuleArgs

{
  config,
  lib,
  pkgs,
  cataCharts,
  k8sSpecs,
  k8sHelpers,
  contracts,
  ...
}@__floeModuleArgs:

let
  inherit ((import ../../../../../lib/floe { inherit lib; })) mkFloe refs;
in
(mkFloe {
  name = "zot";
  version = "0.1.62";
  imports = [ ./options.nix ];
  exports =
    { lib, ... }:
    {
      host = lib.mkOption {
        type = lib.types.str;
        default = "zot.zot.svc.cluster.local";
      };
      namespace = lib.mkOption {
        type = lib.types.str;
        default = "zot";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 5000;
      };
      url = lib.mkOption {
        type = lib.types.str;
        default = "http://zot.zot.svc.cluster.local:5000";
      };
      externalUrl = lib.mkOption {
        type = lib.types.str;
        default = "";
      };
      registryUrl = lib.mkOption {
        type = lib.types.str;
        default = "";
      };
      domain = lib.mkOption {
        type = lib.types.str;
        default = "";
      };
    };
  module =
    {
      config,
      lib,
      cfg,
      peers,
      contracts,
      ...
    }:
    let
      inherit (lib) optionalAttrs optional;

      httpRouteResource = optionalAttrs (cfg.gateway.enable && cfg.domain != "") {
        zot-route = {
          apiVersion = "gateway.networking.k8s.io/v1";
          kind = "HTTPRoute";
          metadata = {
            name = "zot";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          spec = {
            parentRefs = [
              (
                {
                  name = cfg.gateway.gatewayRef;

                  sectionName = config.floes.gateway.exports.terminatingListenerName or "https";
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
                    name = "zot";
                    port = cfg.http.port;
                  }
                ];
              }
            ];
          };
        };
      };

      tlsCertResource = optionalAttrs (cfg.tls.issuerRef != null && cfg.domain != "") {
        zot-tls = {
          apiVersion = "cert-manager.io/v1";
          kind = "Certificate";
          metadata = {
            name = cfg.tls.secretName;
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
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

      authConfig =
        optionalAttrs cfg.oidc.enable {
          openid.providers.oidc = {
            name = cfg.oidc.providerName;
            issuer = cfg.oidc.issuerUrl;
            clientid = cfg.oidc.clientId;
            scopes = cfg.oidc.scopes;
          };
        }
        // optionalAttrs cfg.auth.enable {
          htpasswd.path = "/auth/htpasswd";
        };

      accessPolicies =
        if cfg.oidc.enable && (cfg.oidc.adminGroups != [ ] || cfg.oidc.readOnlyGroups != [ ]) then
          {
            repositories."**" = {
              policies =
                (map (group: {
                  users = [ ];
                  groups = [ group ];
                  actions = [
                    "read"
                    "create"
                    "update"
                    "delete"
                  ];
                }) cfg.oidc.adminGroups)
                ++ (map (group: {
                  users = [ ];
                  groups = [ group ];
                  actions = [ "read" ];
                }) cfg.oidc.readOnlyGroups);
              anonymousPolicy = [ ];
              defaultPolicy = [ "read" ];
            };
          }
        else
          { };

      zotConfig =
        lib.recursiveUpdate
          {
            distSpecVersion = "1.1.0";
            storage = {
              rootDirectory = cfg.storage.rootDirectory;
              dedupe = cfg.storage.dedupe;
              gc = true;
              gcDelay = "1h";
              gcInterval = "24h";
            };
            http = {
              address = "0.0.0.0";
              port = toString cfg.http.port;
            };
            log.level = "info";
            extensions = {
              search.enable = cfg.search.enable;
              ui.enable = cfg.ui.enable;
              metrics.enable = true;
            };
          }
          (
            lib.recursiveUpdate (optionalAttrs (authConfig != { }) { http.auth = authConfig; }) (
              optionalAttrs (accessPolicies != { }) { http.accessControl = accessPolicies; }
            )
          );

      host = "zot.${cfg.namespace}.svc.cluster.local";
    in
    {
      cluster.registryDomains = lib.optional (cfg.domain != "") cfg.domain;

      assertions = [
        {
          assertion = !(cfg.gateway.enable && cfg.domain != "") || (peers.gateway.routing != null);
          message = "zot HTTPRoute requires floes.gateway to be enabled.";
        }
        {
          assertion = cfg.tls.issuerRef == null || (peers.cert-manager.issuance != null);
          message = "zot tls.issuerRef is set but floes.cert-manager is disabled; the Certificate CR will not reconcile.";
        }
        {
          assertion = !cfg.oidc.enable || cfg.oidc.client != null;
          message = "zot OIDC login is enabled but no identity provider publishes an OAuth2 client named \"${cfg.oidc.clientId}\".";
        }
      ]
      ++ optional cfg.oidc.enable (
        contracts.oidc.scopeAssertion {
          consumer = "zot";
          inherit (cfg.oidc) clientId scopes client;
        }
      );

      floes.zot.exports = {
        inherit host;
        inherit (cfg) namespace domain;
        port = cfg.http.port;
        url = "http://${host}:${toString cfg.http.port}";
        externalUrl = if cfg.domain != "" then "https://${cfg.domain}" else "";
        registryUrl = if cfg.domain != "" then cfg.domain else "${host}:${toString cfg.http.port}";
      };

      bundles.zot = {
        resources = tlsCertResource // httpRouteResource;

        helmCharts.zot = {
          chart = cfg.chart;
          releaseName = "zot";
          namespace = cfg.namespace;
          createNamespace = true;
          values = {
            replicaCount = cfg.replicas;

            persistence = {
              enabled = true;
              size = cfg.storage.size;
            }
            // optionalAttrs (cfg.storage.storageClass != null) {
              storageClassName = cfg.storage.storageClass;
            };

            service = {
              type = "ClusterIP";
              port = cfg.http.port;
            };

            extraVolumes =
              (optional cfg.auth.enable {
                name = "htpasswd";
                secret.secretName = cfg.auth.htpasswdSecret;
              })
              ++ (optional (cfg.oidc.enable && cfg.tls.caBundle != null) {
                name = "lab-ca";
                configMap.name = cfg.tls.caBundle.name;
              });

            extraVolumeMounts =
              (optional cfg.auth.enable {
                name = "htpasswd";
                mountPath = "/auth";
                readOnly = true;
              })
              ++ (optional (cfg.oidc.enable && cfg.tls.caBundle != null) {
                name = "lab-ca";
                mountPath = "/etc/ssl/certs/lab-ca.crt";
                subPath = cfg.tls.caBundle.key;
                readOnly = true;
              });

            extraEnvVars = optional (cfg.oidc.enable && cfg.oidc.clientSecretRef != null) {
              name = "ZOT_OPENID_PROVIDERS_KANIDM_CLIENTSECRET";
              valueFrom.secretKeyRef = {
                name = cfg.oidc.clientSecretRef.name;
                key = cfg.oidc.clientSecretRef.key;
              };
            };

            mountConfig = true;
            configFiles."config.json" = builtins.toJSON zotConfig;
          };
        };

        createNamespaces = [ cfg.namespace ];

        requires =
          refs.needs peers.cert-manager.issuance "webhookReady"
          ++ refs.needs peers.gateway.routing "publicReady"

          ++ optional (
            cfg.oidc.enable && cfg.tls.caBundle != null && cfg.tls.caBundle.readyToken != null
          ) cfg.tls.caBundle.readyToken;
        provides = [ "zot/registry/ready" ];
        readyProbe = {
          kind = "condition";
          resource = "statefulset/zot";
          namespace = cfg.namespace;
          condition = "Available";
          timeout = "5m";
        };
      };
    };
})
  __floeModuleArgs

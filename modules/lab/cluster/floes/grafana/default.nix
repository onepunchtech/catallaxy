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
  name = "grafana";
  version = "8.5.2";
  imports = [ ./options.nix ];

  requires = [
    "gateway"
    "reloader"
  ];
  exports =
    { lib, ... }:
    {
      host = lib.mkOption {
        type = lib.types.str;
        default = "grafana.grafana.svc.cluster.local";
        description = "In-cluster DNS name of the Grafana Service.";
      };
      namespace = lib.mkOption {
        type = lib.types.str;
        default = "grafana";
        description = "Namespace Grafana runs in.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 80;
        description = "Port the Service listens on.";
      };
      url = lib.mkOption {
        type = lib.types.str;
        default = "http://grafana.grafana.svc.cluster.local:80";
        description = "In-cluster URL, for peers that reach Grafana without leaving the cluster.";
      };
      externalUrl = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Public HTTPS URL, or empty when no domain is set.";
      };
      domain = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Public hostname, or empty when Grafana is internal only.";
      };
    };
  module =
    {
      config,
      lib,
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
        concatStringsSep
        ;
      promCfg = config.floes.prometheus;
      lokiCfg = config.floes.loki;
      tempoCfg = config.floes.tempo;

      chartRef = cfg.chart;

      prometheusUrl =
        if cfg.datasources.prometheus.url != null then
          cfg.datasources.prometheus.url
        else if promCfg.enable then
          promCfg.exports.url
        else
          null;

      lokiUrl =
        if cfg.datasources.loki.url != null then
          cfg.datasources.loki.url
        else if lokiCfg.enable then
          lokiCfg.exports.url
        else
          null;

      tempoUrl =
        if cfg.datasources.tempo.url != null then
          cfg.datasources.tempo.url
        else if tempoCfg.enable then
          tempoCfg.exports.url
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

        auth = {
          disable_login_form = cfg.oidc.autoLogin;
        };
      };

      oidcEnvVars = optional (cfg.oidc.enable && cfg.oidc.clientSecretRef != null) {
        name = "GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET";
        valueFrom = {
          secretKeyRef = {
            name = cfg.oidc.clientSecretRef.name;
            key = cfg.oidc.clientSecretRef.key;
          };
        };
      };

      hasOidcCaCert =
        cfg.oidc.enable && (cfg.oidc.tlsCaCertSecretRef != null || cfg.oidc.tlsCaBundle != null);
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
        else if cfg.oidc.enable && cfg.oidc.tlsCaBundle != null then
          [
            {
              name = "oidc-ca-cert";
              configMap.name = cfg.oidc.tlsCaBundle.name;
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
              subPath = if cfg.oidc.tlsCaCertSecretRef != null then "ca.crt" else cfg.oidc.tlsCaBundle.key;
              readOnly = true;
            }
          ]
        else
          [ ];

      host = "grafana.${cfg.namespace}.svc.cluster.local";
    in
    {
      floes.grafana.exports = {
        inherit host;
        inherit (cfg) namespace domain;
        port = 80;
        url = "http://${host}:80";
        externalUrl = "https://${cfg.domain}";
      };

      assertions = optional cfg.oidc.enable (
        contracts.oidc.scopeAssertion {
          consumer = "grafana";
          inherit (cfg.oidc) clientId scopes client;
        }
      );

      floes.gateway.internalHostnames =
        if cfg.gateway.enable && cfg.gateway.tier == "internal" && cfg.domain != "" then
          [ cfg.domain ]
        else
          [ ];

      floes.grafana.network = {

        declared = true;

        serves.http.port = 80;

        reaches = [

          "prometheus/api"

          "loki/api"

          "tempo/api"

        ];

      };

      floes.grafana.imagesComplete = true;

      floes.grafana.images.grafana = {

        repository = "grafana/grafana";

        tag = "12.3.1";

      };

      floes.grafana.images.downloader = {

        repository = "library/busybox";

        tag = "1.31.1";

      };

      floes.grafana.images.sidecar = {

        registry = "quay.io";

        repository = "kiwigrid/k8s-sidecar";

        tag = "2.5.0";

      };

      bundles.grafana = {
        helmCharts.grafana = {
          chart = chartRef;
          releaseName = "grafana";
          namespace = cfg.namespace;
          createNamespace = true;
          kustomize = lib.optionalAttrs (cfg.oidc.enable && cfg.oidc.clientSecretRef != null) {
            enable = true;
            patches = config.floes.reloader.exports.mkPatches [
              {
                kind = "Deployment";
                name = "grafana";
                secrets = [ cfg.oidc.clientSecretRef.name ];
              }
            ];
          };
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

        resources = k8sHelpers.mkGatewayExposure {
          name = "grafana";
          routeName = "grafana-httproute";
          namespace = cfg.namespace;
          inherit (cfg) domain gateway tls;
          inherit (config.floes.gateway.exports) internalGatewayName;
          sectionName = config.floes.gateway.exports.terminatingListenerName or "https";
          backend = {
            name = "grafana";
            port = 80;
          };
        };

        createNamespaces = [ cfg.namespace ];

        requires =
          refs.needs peers.gateway.routing "publicReady" ++ refs.needs peers.reloader.watching "ready";

        after =
          refs.orderAfter peers.prometheus.metrics "scrapeReady"
          ++ refs.orderAfter peers.loki.logIngest "ready"
          ++ refs.orderAfter peers.tempo.traceIngest "ready";
        provides = [ "grafana/ui/ready" ];
        readyProbe = {
          kind = "condition";
          resource = "deployment/grafana";
          namespace = cfg.namespace;
          condition = "Available";
          timeout = "5m";
        };
      };
    };
})
  __floeModuleArgs

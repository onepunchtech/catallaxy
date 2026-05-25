# modules/cluster/components/zot.nix
#
# Zot OCI-native container registry component — merged high-level options + IR writer.
#
# A vendor-neutral, OCI-native container image registry.
# Supports OIDC authentication via Kanidm.

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
    ;
  cfg = config.components.zot;

  # Chart reference with fallback
  chartRef = cfg.chart;

  # HTTPRoute for Gateway API
  httpRouteResource = optionalAttrs (cfg.gateway.enable && cfg.domain != "") {
    zot-route = {
      apiVersion = "gateway.networking.k8s.io/v1";
      kind = "HTTPRoute";
      metadata = {
        name = "zot";
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
                name = "zot";
                port = cfg.http.port;
              }
            ];
          }
        ];
      };
    };
  };

  # TLS Certificate
  tlsCertResource = optionalAttrs (cfg.tls.issuerRef != null && cfg.domain != "") {
    zot-tls = {
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

  # Build authentication configuration
  authConfig =
    if cfg.oidc.enable then
      {
        openid = {
          providers = {
            kanidm = {
              issuer = cfg.oidc.issuerUrl;
              clientid = cfg.oidc.clientId;
              scopes = cfg.oidc.scopes;
            };
          };
        };
      }
    else if cfg.auth.enable then
      {
        htpasswd = {
          path = "/auth/htpasswd";
        };
      }
    else
      { };

  # Access control policies
  accessPolicies =
    if cfg.oidc.enable && (cfg.oidc.adminGroups != [ ] || cfg.oidc.readOnlyGroups != [ ]) then
      {
        repositories = {
          "**" = {
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
        };
      }
    else
      { };

  # Zot configuration
  zotConfig = {
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
    log = {
      level = "info";
    };
    extensions = {
      search = {
        enable = cfg.search.enable;
      };
      ui = {
        enable = cfg.ui.enable;
      };
      metrics = {
        enable = true;
      };
    };
  }
  // optionalAttrs (authConfig != { }) {
    http.auth = authConfig;
  }
  // optionalAttrs (accessPolicies != { }) {
    accessControl = accessPolicies;
  };
in
{
  # =========================================================================
  # PART 1: High-level options
  # =========================================================================

  options.components.zot = {
    enable = mkEnableOption "Zot OCI-native container registry";

    phase = mkOption {
      type = types.str;
      default = "apps";
    };
    version = mkOption {
      type = types.str;
      default = "0.1.62";
    };
    chart = mkOption {
      type = types.package;
      default = cataCharts.zot.chart;
    };
    namespace = mkOption {
      type = types.str;
      default = "zot";
    };
    domain = mkOption {
      type = types.str;
      default = "";
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
        default = "zot-tls";
      };
    };

    storage = {
      rootDirectory = mkOption {
        type = types.str;
        default = "/var/lib/zot";
      };
      size = mkOption {
        type = types.str;
        default = "50Gi";
      };
      storageClass = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      dedupe = mkOption {
        type = types.bool;
        default = true;
      };
    };

    auth = {
      enable = mkOption {
        type = types.bool;
        default = false;
      };
      htpasswdSecret = mkOption {
        type = types.str;
        default = "zot-htpasswd";
      };
    };

    oidc = {
      enable = mkEnableOption "OIDC authentication via Kanidm";
      issuerUrl = mkOption {
        type = types.str;
        default = "";
      };
      clientId = mkOption {
        type = types.str;
        default = "zot";
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
          "groups"
        ];
      };
      usernameClaim = mkOption {
        type = types.str;
        default = "preferred_username";
      };
      groupsClaim = mkOption {
        type = types.str;
        default = "groups";
      };
      adminGroups = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
      readOnlyGroups = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
    };

    search = {
      enable = mkOption {
        type = types.bool;
        default = true;
      };
    };
    ui = {
      enable = mkOption {
        type = types.bool;
        default = true;
      };
    };
    http = {
      port = mkOption {
        type = types.port;
        default = 5000;
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

  # =========================================================================
  # PART 2: Computed refs and config
  # =========================================================================

  config = lib.mkMerge [
    {
      components.zot.ref =
        let
          host = "zot.${cfg.namespace}.svc.cluster.local";
        in
        {
          inherit host;
          namespace = cfg.namespace;
          port = cfg.http.port;
          url = "http://${host}:${toString cfg.http.port}";
          externalUrl = if cfg.domain != "" then "https://${cfg.domain}" else "";
          registryUrl = if cfg.domain != "" then cfg.domain else "${host}:${toString cfg.http.port}";
          domain = cfg.domain;
        };
    }

    # =========================================================================
    # PART 3: Phase writer
    # =========================================================================

    (mkIf cfg.enable {
      phases.${cfg.phase}.bundles.zot = {
        resources = tlsCertResource // httpRouteResource;

        helmCharts.zot = {
          chart = chartRef;
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

            extraVolumes = optional cfg.auth.enable {
              name = "htpasswd";
              secret = {
                secretName = cfg.auth.htpasswdSecret;
              };
            };

            extraVolumeMounts = optional cfg.auth.enable {
              name = "htpasswd";
              mountPath = "/auth";
              readOnly = true;
            };

            extraEnvVars = optional (cfg.oidc.enable && cfg.oidc.clientSecretRef != null) {
              name = "ZOT_OPENID_PROVIDERS_KANIDM_CLIENTSECRET";
              valueFrom.secretKeyRef = {
                name = cfg.oidc.clientSecretRef.name;
                key = cfg.oidc.clientSecretRef.key;
              };
            };

            configFiles = {
              "config.json" = builtins.toJSON zotConfig;
            };
          };
        };

        createNamespaces = [ cfg.namespace ];
      };
    })
  ];
}

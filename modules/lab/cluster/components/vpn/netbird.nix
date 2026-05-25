# modules/cluster/components/netbird.nix
#
# Netbird mesh VPN component — merged high-level options + IR writer.
#
# Provides WireGuard-based zero-trust networking with
# identity-aware access control. Integrates with Kanidm or
# other OIDC providers for authentication.

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
    ;
  cfg = config.components.netbird;

  # Chart reference with fallback
  chartRef = cfg.chart;
in
{
  # =========================================================================
  # PART 1: High-level options
  # =========================================================================

  options.components.netbird = {
    enable = mkEnableOption "Netbird mesh VPN";

    phase = mkOption {
      type = types.str;
      default = "infrastructure";
      description = "Deployment phase this component belongs to";
    };

    version = mkOption {
      type = types.str;
      default = "0.31.0";
      description = "Netbird version";
    };

    namespace = mkOption {
      type = types.str;
      default = "netbird";
      description = "Namespace for Netbird";
    };

    chart = mkOption {
      type = types.package;
      default = cataCharts.netbird.chart;
      description = "Custom chart derivation. When null, uses nixhelm default.";
    };

    # Domain configuration
    domain = mkOption {
      type = types.str;
      default = "vpn.example.com";
      description = "Domain name for the Netbird management server";
    };

    # Management server
    management = {
      replicas = mkOption {
        type = types.ints.positive;
        default = 1;
        description = "Number of management server replicas";
      };

      storage = {
        size = mkOption {
          type = types.str;
          default = "5Gi";
          description = "PVC size for management server data";
        };

        storageClass = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "StorageClass (null = cluster default)";
        };
      };
    };

    # Signal server
    signal = {
      replicas = mkOption {
        type = types.ints.positive;
        default = 1;
        description = "Number of signal server replicas";
      };
    };

    # TURN relay server
    turn = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable TURN relay for NAT traversal";
      };

      domain = mkOption {
        type = types.str;
        default = "turn.example.com";
        description = "Domain for the TURN server";
      };
    };

    # OIDC/IDP integration
    idp = {
      issuer = mkOption {
        type = types.str;
        default = "";
        description = ''
          OIDC issuer URL. Use config.components.kanidm.ref.oidcIssuer
          for type-safe Kanidm integration.
        '';
      };

      clientID = mkOption {
        type = types.str;
        default = "netbird";
        description = "OIDC client ID";
      };

      clientSecretRef = mkOption {
        type = types.nullOr types.attrs;
        default = null;
        description = ''
          Reference to the OIDC client secret.
          Use config.secrets.managed.<name>.ref.secretRef for type-safe refs.
        '';
      };
    };

    ref = mkOption {
      type = types.attrs;
      readOnly = true;
      description = "Computed references for Netbird";
    };
  };

  # =========================================================================
  # PART 2: Computed refs and config
  # =========================================================================

  config = lib.mkMerge [
    {
      components.netbird.ref =
        let
          host = "netbird-management.${cfg.namespace}.svc.cluster.local";
        in
        {
          inherit host;
          namespace = cfg.namespace;
          managementUrl = "https://${cfg.domain}";
          managementInternalUrl = "http://${host}:80";
          signalHost = "netbird-signal.${cfg.namespace}.svc.cluster.local";
          signalPort = 10000;
          domain = cfg.domain;
        };
    }

    # =========================================================================
    # PART 3: Phase writer
    # =========================================================================

    (mkIf cfg.enable {
      # Netbird helm chart
      phases.${cfg.phase}.bundles.netbird = {
        helmCharts.netbird = {
          chart = chartRef;
          releaseName = "netbird";
          namespace = cfg.namespace;
          createNamespace = true;
          values = {
            management = {
              replicas = cfg.management.replicas;
              domain = cfg.domain;

              persistence = {
                enabled = true;
                size = cfg.management.storage.size;
              }
              // optionalAttrs (cfg.management.storage.storageClass != null) {
                storageClass = cfg.management.storage.storageClass;
              };

              idp =
                optionalAttrs (cfg.idp.issuer != "") {
                  issuer = cfg.idp.issuer;
                  clientID = cfg.idp.clientID;
                }
                // optionalAttrs (cfg.idp.clientSecretRef != null) {
                  existingSecret = cfg.idp.clientSecretRef;
                };
            };

            signal = {
              replicas = cfg.signal.replicas;
            };

            turn = {
              enabled = cfg.turn.enable;
            }
            // optionalAttrs cfg.turn.enable {
              domain = cfg.turn.domain;
            };
          };
        };

        # Namespace creation
        createNamespaces = [ cfg.namespace ];
      };
    })
  ];
}

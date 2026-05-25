# modules/cluster/components/cert-manager.nix
#
# cert-manager component — merged high-level options + IR writer.
#
# cert-manager provides X.509 certificate management for Kubernetes,
# supporting ACME (Let's Encrypt), self-signed CAs, and various other
# certificate authorities.
#
# This file combines:
# - modules/components/cert-manager.nix (high-level options)
# - modules/nixidy/cert-manager.nix (manifest generation)
#
# Instead of writing to nixidy.applications, this component writes
# directly to ir.phases for build-time manifest rendering.

{
  config,
  lib,
  pkgs,
  cataCharts,
  ...
}:

let
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    ;
  cfg = config.components.cert-manager;

  # Chart reference with fallback
  chartRef = cfg.chart;
in
{
  # =========================================================================
  # PART 1: High-level options (from components/cert-manager.nix)
  # =========================================================================

  options.components.cert-manager = {
    enable = mkEnableOption "cert-manager";

    phase = mkOption {
      type = types.str;
      default = "operators";
      description = "Deployment phase this component belongs to";
    };

    version = mkOption {
      type = types.str;
      default = "v1.16.1";
      description = "cert-manager version";
    };

    chart = mkOption {
      type = types.package;
      default = cataCharts.cert-manager.chart;
      description = "cert-manager Helm chart derivation (default: cataCharts.cert-manager)";
    };

    namespace = mkOption {
      type = types.str;
      default = "cert-manager";
      description = "Namespace for cert-manager";
    };

    # Self-signed CA for issuing TLS certificates (useful for labs/dev)
    selfSignedCA = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Create a self-signed CA ClusterIssuer";
      };

      issuerName = mkOption {
        type = types.str;
        default = "lab-ca";
        description = "Name of the ClusterIssuer backed by the self-signed CA";
      };
    };

    # ACME (Let's Encrypt) configuration
    acme = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Create an ACME ClusterIssuer for Let's Encrypt";
      };

      email = mkOption {
        type = types.str;
        default = "";
        description = "Email for ACME registration";
      };

      server = mkOption {
        type = types.str;
        default = "https://acme-v02.api.letsencrypt.org/directory";
        description = "ACME server URL (use staging for testing)";
      };

      issuerName = mkOption {
        type = types.str;
        default = "letsencrypt";
        description = "Name of the ACME ClusterIssuer";
      };

      solvers = mkOption {
        type = types.listOf types.attrs;
        default = [ ];
        description = "Raw ACME solver config (overrides dns01 provider if set)";
      };

      dns01 = {
        provider = mkOption {
          type = types.enum [
            "none"
            "cloudflare"
            "route53"
          ];
          default = "none";
          description = "Public DNS provider for ACME DNS01 challenges";
        };

        cloudflare = {
          apiTokenSecretName = mkOption {
            type = types.str;
            default = "cloudflare-api-token";
            description = "Name of Secret containing the Cloudflare API token (key: api-token)";
          };

          apiToken = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Cloudflare API token (if set, auto-creates the Secret)";
          };
        };

        route53 = {
          region = mkOption {
            type = types.str;
            default = "us-east-1";
            description = "AWS region for Route53";
          };

          hostedZoneID = mkOption {
            type = types.str;
            default = "";
            description = "Route53 hosted zone ID";
          };

          accessKeyID = mkOption {
            type = types.str;
            default = "";
            description = "AWS access key ID (for explicit credentials)";
          };

          secretAccessKeySecretName = mkOption {
            type = types.str;
            default = "route53-credentials";
            description = "Name of Secret containing AWS secret access key (key: secret-access-key)";
          };

          secretAccessKey = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "AWS secret access key (if set, auto-creates the Secret)";
          };
        };
      };
    };

    # Computed refs for other components to reference
    ref = mkOption {
      type = types.attrs;
      readOnly = true;
      description = "Computed references for cert-manager";
    };
  };

  # =========================================================================
  # PART 2: Computed refs
  # =========================================================================

  # =========================================================================
  # PART 3: CRD management (legacy integration)
  # =========================================================================

  config = lib.mkMerge [
    {
      components.cert-manager.ref = {
        namespace = cfg.namespace;
        # Default issuer to use
        defaultIssuer =
          if cfg.acme.enable then
            cfg.acme.issuerName
          else if cfg.selfSignedCA.enable then
            cfg.selfSignedCA.issuerName
          else
            null;
        # Issuer refs for Certificate resources
        selfSignedIssuerRef = mkIf cfg.selfSignedCA.enable {
          name = cfg.selfSignedCA.issuerName;
          kind = "ClusterIssuer";
        };

        acmeIssuerRef = mkIf cfg.acme.enable {
          name = cfg.acme.issuerName;
          kind = "ClusterIssuer";
        };

        # Trust bundle refs — components use these to mount the CA
        caBundleConfigMap = "lab-ca-bundle";
        caBundleKey = "ca.crt";
        caBundleNamespaceLabel = {
          "catallaxy.io/trust-bundle" = "true";
        };
      };
    }
    (mkIf cfg.enable {
      # CRDs in the crds phase
      phases.crds.bundles.cert-manager-crds.yamls = [ cataCharts.cert-manager.crds ];

      # =========================================================================
      # PART 4: Phase writer (replaces nixidy/cert-manager.nix)
      # =========================================================================

      # Main cert-manager helm chart + namespace
      phases.${cfg.phase}.bundles.cert-manager = {
        helmCharts.cert-manager = {
          chart = chartRef;
          releaseName = "cert-manager";
          namespace = cfg.namespace;
          createNamespace = true;
          values = {
            installCRDs = false;
          };
        };
        createNamespaces = [ cfg.namespace ];
      };

      # Self-signed CA issuers (deployed in infrastructure phase)
      phases.infrastructure.bundles.cert-manager-issuers.resources = lib.mkMerge [
        (mkIf cfg.selfSignedCA.enable {
          # ClusterIssuer backed by the lab CA secret.
          # The secret (lab-ca-ca-secret) is either:
          # - Pre-populated by the CLI from the ingress CA (same CA for everything)
          # - Or bootstrapped by cert-manager's self-signed issuer (fallback)
          "${cfg.selfSignedCA.issuerName}" = {
            apiVersion = "cert-manager.io/v1";
            kind = "ClusterIssuer";
            metadata.name = cfg.selfSignedCA.issuerName;
            spec.ca.secretName = "${cfg.selfSignedCA.issuerName}-ca-secret";
          };
        })

        # Trust bundle distribution (requires trust-manager)
        (mkIf (cfg.selfSignedCA.enable && (config.components.trust-manager.enable or false)) {
          "lab-ca-bundle" = {
            apiVersion = "trust.cert-manager.io/v1alpha1";
            kind = "Bundle";
            metadata.name = "lab-ca-bundle";
            spec = {
              sources = [
                {
                  secret = {
                    name = "${cfg.selfSignedCA.issuerName}-ca-secret";
                    key = "tls.crt";
                  };
                }
              ];
              target = {
                configMap = {
                  key = "ca.crt";
                };
                namespaceSelector = { }; # all namespaces
              };
            };
          };
        })

        # ACME issuer (deployed in infrastructure phase)
        (mkIf cfg.acme.enable (
          let
            dns01Cfg = cfg.acme.dns01;

            cloudflareSolver = [
              {
                dns01.cloudflare = {
                  apiTokenSecretRef = {
                    name = dns01Cfg.cloudflare.apiTokenSecretName;
                    key = "api-token";
                  };
                };
              }
            ];

            route53Solver = [
              {
                dns01.route53 = {
                  region = dns01Cfg.route53.region;
                }
                // lib.optionalAttrs (dns01Cfg.route53.hostedZoneID != "") {
                  hostedZoneID = dns01Cfg.route53.hostedZoneID;
                }
                // lib.optionalAttrs (dns01Cfg.route53.accessKeyID != "") {
                  accessKeyID = dns01Cfg.route53.accessKeyID;
                  secretAccessKeySecretRef = {
                    name = dns01Cfg.route53.secretAccessKeySecretName;
                    key = "secret-access-key";
                  };
                };
              }
            ];

            effectiveSolvers =
              if cfg.acme.solvers != [ ] then
                cfg.acme.solvers
              else if dns01Cfg.provider == "cloudflare" then
                cloudflareSolver
              else if dns01Cfg.provider == "route53" then
                route53Solver
              else
                [ ];
          in
          {
            "${cfg.acme.issuerName}" = {
              apiVersion = "cert-manager.io/v1";
              kind = "ClusterIssuer";
              metadata.name = cfg.acme.issuerName;
              spec.acme = {
                email = cfg.acme.email;
                server = cfg.acme.server;
                privateKeySecretRef.name = "${cfg.acme.issuerName}-account-key";
                solvers = effectiveSolvers;
              };
            };
          }
          // lib.optionalAttrs (dns01Cfg.provider == "cloudflare" && dns01Cfg.cloudflare.apiToken != null) {
            "${dns01Cfg.cloudflare.apiTokenSecretName}" = {
              apiVersion = "v1";
              kind = "Secret";
              metadata = {
                name = dns01Cfg.cloudflare.apiTokenSecretName;
                namespace = cfg.namespace;
              };
              type = "Opaque";
              stringData = {
                "api-token" = dns01Cfg.cloudflare.apiToken;
              };
            };
          }
          // lib.optionalAttrs (dns01Cfg.provider == "route53" && dns01Cfg.route53.secretAccessKey != null) {
            "${dns01Cfg.route53.secretAccessKeySecretName}" = {
              apiVersion = "v1";
              kind = "Secret";
              metadata = {
                name = dns01Cfg.route53.secretAccessKeySecretName;
                namespace = cfg.namespace;
              };
              type = "Opaque";
              stringData = {
                "secret-access-key" = dns01Cfg.route53.secretAccessKey;
              };
            };
          }
        ))
      ];
    })
  ];
}

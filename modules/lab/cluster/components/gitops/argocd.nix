# modules/cluster/components/argocd.nix
#
# ArgoCD component — merged high-level options + IR writer.
#
# GitOps continuous delivery tool for Kubernetes.
# Supports repository credentials, OIDC authentication, and HA mode.

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
    mapAttrsToList
    filterAttrs
    optionalAttrs
    optionals
    optional
    ;
  cfg = config.components.argocd;

  # Chart reference with fallback
  chartRef = cfg.chart;

  # Filter repositories that have credentials
  reposWithCreds = filterAttrs (
    _: repo:
    repo.usernameSecretRef != null
    || repo.passwordSecretRef != null
    || repo.sshPrivateKeySecretRef != null
  ) cfg.repositories;

  # Generate repository credential secrets
  # ArgoCD expects secrets with specific labels and keys
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

  # OIDC configuration for ArgoCD (via Dex)
  hasOidcCaBundle = cfg.oidc.caBundleConfigMap != null;
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

    # Mount CA bundle into Dex container
    dex = optionalAttrs hasOidcCaBundle {
      volumeMounts = [
        {
          name = "oidc-ca-bundle";
          mountPath = oidcCaCertPath;
          subPath = cfg.oidc.caBundleKey;
          readOnly = true;
        }
      ];
      volumes = [
        {
          name = "oidc-ca-bundle";
          configMap.name = cfg.oidc.caBundleConfigMap;
        }
      ];
    };
  };

in
{
  # =========================================================================
  # PART 1: High-level options
  # =========================================================================

  options.components.argocd = {
    enable = mkEnableOption "ArgoCD";

    phase = mkOption {
      type = types.str;
      default = "gitops";
      description = "Deployment phase this component belongs to";
    };

    version = mkOption {
      type = types.str;
      default = "v2.13.0";
      description = "ArgoCD version";
    };

    chart = mkOption {
      type = types.package;
      default = cataCharts.argocd.chart;
      description = "ArgoCD Helm chart derivation (default: cataCharts.argocd)";
    };

    namespace = mkOption {
      type = types.str;
      default = "argocd";
      description = "Namespace for ArgoCD";
    };

    ha = mkOption {
      type = types.bool;
      default = false;
      description = "Install HA version of ArgoCD";
    };

    # Repository credentials
    repositories = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            url = mkOption {
              type = types.str;
              description = "Repository URL";
            };

            type = mkOption {
              type = types.enum [
                "git"
                "helm"
              ];
              default = "git";
              description = "Repository type";
            };

            usernameSecretRef = mkOption {
              type = types.nullOr (
                types.submodule {
                  options = {
                    name = mkOption {
                      type = types.str;
                      description = "Secret containing username";
                    };
                    key = mkOption {
                      type = types.str;
                      default = "username";
                      description = "Key within the secret";
                    };
                  };
                }
              );
              default = null;
              description = "Reference to Secret containing repository username";
            };

            passwordSecretRef = mkOption {
              type = types.nullOr (
                types.submodule {
                  options = {
                    name = mkOption {
                      type = types.str;
                      description = "Secret containing password/token";
                    };
                    key = mkOption {
                      type = types.str;
                      default = "password";
                      description = "Key within the secret";
                    };
                  };
                }
              );
              default = null;
              description = "Reference to Secret containing repository password or access token";
            };

            sshPrivateKeySecretRef = mkOption {
              type = types.nullOr (
                types.submodule {
                  options = {
                    name = mkOption {
                      type = types.str;
                      description = "Secret containing SSH private key";
                    };
                    key = mkOption {
                      type = types.str;
                      default = "ssh-privatekey";
                      description = "Key within the secret";
                    };
                  };
                }
              );
              default = null;
              description = "Reference to Secret containing SSH private key for repository access";
            };

            insecure = mkOption {
              type = types.bool;
              default = false;
              description = "Skip TLS certificate verification";
            };

            tlsClientCertSecretRef = mkOption {
              type = types.nullOr (
                types.submodule {
                  options = {
                    name = mkOption {
                      type = types.str;
                      description = "Secret containing TLS client certificate";
                    };
                    certKey = mkOption {
                      type = types.str;
                      default = "tls.crt";
                      description = "Key for the certificate";
                    };
                    keyKey = mkOption {
                      type = types.str;
                      default = "tls.key";
                      description = "Key for the private key";
                    };
                  };
                }
              );
              default = null;
              description = "Reference to Secret containing TLS client certificate for repository access";
            };

            enableLfs = mkOption {
              type = types.bool;
              default = false;
              description = "Enable Git LFS for this repository";
            };

            project = mkOption {
              type = types.str;
              default = "default";
              description = "ArgoCD project to associate this repository with";
            };
          };
        }
      );
      default = { };
      description = "Repository credentials for ArgoCD";
    };

    # OIDC configuration for ArgoCD (optional - for Dex integration)
    oidc = {
      enable = mkEnableOption "OIDC authentication";

      issuerUrl = mkOption {
        type = types.str;
        default = "";
        description = "OIDC issuer URL";
      };

      clientId = mkOption {
        type = types.str;
        default = "argocd";
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

      name = mkOption {
        type = types.str;
        default = "Kanidm";
        description = "Display name for OIDC provider";
      };

      caBundleConfigMap = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "ConfigMap containing CA bundle for OIDC issuer TLS verification (from trust-manager)";
      };

      caBundleKey = mkOption {
        type = types.str;
        default = "ca.crt";
        description = "Key within the CA bundle ConfigMap";
      };
    };

    domain = mkOption {
      type = types.str;
      default = "";
      description = "Domain for ArgoCD external access";
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
        description = "cert-manager issuer reference for ArgoCD TLS certificate";
      };

      secretName = mkOption {
        type = types.str;
        default = "argocd-tls";
        description = "Name of the TLS Secret created by cert-manager";
      };
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
      description = "Computed references for ArgoCD";
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
      components.argocd.ref =
        let
          host = "argocd-server.${cfg.namespace}.svc.cluster.local";
        in
        {
          inherit host;
          namespace = cfg.namespace;
          port = 443;
          url = "https://${host}";
          grpcUrl = "${host}:443";
          domain = cfg.domain;
          externalUrl = if cfg.domain != "" then "https://${cfg.domain}" else "https://${host}";
        };
    }
    (mkIf cfg.enable {
      phases.${cfg.phase}.bundles.argocd = {
        # ArgoCD helm chart
        helmCharts.argocd = {
          chart = chartRef;
          releaseName = "argocd";
          namespace = cfg.namespace;
          createNamespace = true;
          values = {
            server.extraArgs = optionals (!cfg.ha) [ "--insecure" ];
            controller.replicas = if cfg.ha then 2 else 1;
            repoServer.replicas = if cfg.ha then 2 else 1;
            applicationSet.replicas = if cfg.ha then 2 else 1;
            configs.secret.createSecret = true;
          }
          // oidcConfig;
        };

        # Repository secrets, TLS cert, and HTTPRoute
        resources =
          repoSecretResources
          // optionalAttrs (cfg.tls.issuerRef != null && cfg.domain != "") {
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
          }
          // optionalAttrs (cfg.gateway.enable && cfg.domain != "") {
            "argocd-httproute" = {
              apiVersion = "gateway.networking.k8s.io/v1";
              kind = "HTTPRoute";
              metadata = {
                name = "argocd";
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
                        name = "argocd-server";
                        port = 80;
                      }
                    ];
                  }
                ];
              };
            };
          };

        # Namespace creation
        createNamespaces = [ cfg.namespace ];
      };

    })
  ];
}

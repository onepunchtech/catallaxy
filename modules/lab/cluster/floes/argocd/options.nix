{
  lab,
  config,
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption mkEnableOption types;
  inherit (import ../../../../../lib/floe { inherit lib; }) gatewayOptions refs;
in
{
  options.floes.argocd = {
    chart = mkOption {
      type = types.package;
      default = cataCharts.argocd.chart;
      description = "ArgoCD Helm chart derivation (default: cataCharts.argocd)";
    };

    ha = mkOption {
      type = types.bool;
      default = false;
      description = "Install HA version of ArgoCD";
    };

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

            verifyWithLabCA = mkOption {
              type = types.bool;
              default = false;
              description = ''
                Verify this repository's certificate against the lab's CA.

                A repository the lab hosts is served under a certificate the
                lab's own CA signed, which no image ships a root for. argocd
                reads repository CAs from the `argocd-tls-certs-cm` ConfigMap
                and nowhere else, keyed by hostname, so pointing it at the
                trust bundle in the namespace does not reach it.

                Setting this hands that ConfigMap to `cata lab up`, which
                writes the lab CA under this repository's hostname while the
                cluster is being created. The chart stops creating it, since
                two owners of one object is how it ends up empty.

                A repository behind a publicly signed certificate needs none
                of this and should leave it off.
              '';
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

      caBundle = mkOption {
        type = refs.nullableMountableRef;
        default = config.floes.cert-manager.exports.caBundle;
        description = ''
          CA bundle mounted into dex so it can verify the OIDC issuer's
          TLS cert. Defaults to whatever cert-manager publishes: null
          when nothing produces one, which is also how you opt out.
        '';
      };
    };

    rbac = {
      defaultRole = mkOption {
        type = types.str;
        default = "";
        description = ''
          Role granted to authenticated users that match no group binding.
          Empty (the default) = no permissions.
        '';
      };

      groupBindings = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = {
          admins = "role:admin";
          devs = "role:readonly";
        };
        description = ''
          Map of OIDC group name to ArgoCD role. Renders one
          `g, <group>, <role>` line per entry into argocd-rbac-cm.
        '';
      };

      extraPolicy = mkOption {
        type = types.lines;
        default = "";
        description = ''
          Extra raw RBAC policy CSV appended after the group bindings.
          Use for custom role definitions (e.g. `p, role:dev, applications, *, */*, allow`).
        '';
      };

      scopes = mkOption {
        type = types.str;
        default = "[groups]";
        description = ''
          OIDC claim(s) to match against group bindings. Default reads
          the `groups` array claim.
        '';
      };
    };

    domain = mkOption {
      type = types.str;
      default = "";
      description = "Domain for ArgoCD external access";
    };

    tls = {
      labCAHosts = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = lib.literalExpression ''[ "git.homelab.test" ]'';
        description = ''
          Hosts whose certificates are signed by the lab's CA.

          The same effect as `repositories.<name>.verifyWithLabCA`, for a
          repository this floe does not register. A registration that
          arrives as a Secret from somewhere else, such as one a subscription
          materialises with credentials in it, still needs argocd to trust
          the host it points at, and declaring it as a repository here only
          to say so would register it twice: argocd would then have two
          entries for one URL and use whichever it found first, which is how
          a working credential stops being used.
        '';
      };

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

        default = config.floes.cert-manager.exports.defaultIssuerRef or null;
        description = "cert-manager issuer reference for ArgoCD TLS certificate";
      };

      secretName = mkOption {
        type = types.str;
        default = "argocd-tls";
        description = "Name of the TLS Secret created by cert-manager";
      };
    };

    gateway = gatewayOptions {
      inherit lab;
    };
  };
}

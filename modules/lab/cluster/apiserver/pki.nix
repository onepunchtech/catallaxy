{ config, lib, ... }:

let
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    mapAttrs
    mapAttrsToList
    ;
  cfg = config.cluster.apiserver.pki;

  rbacResources = mapAttrs (name: binding: {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    metadata = {
      name = "pki-${name}";
      labels = {
        "app.kubernetes.io/managed-by" = "catallaxy";
      };
    };
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io";
      kind = "ClusterRole";
      name = binding.clusterRole;
    };
    subjects = [
      {
        kind = "Group";
        name = binding.organization;
        apiGroup = "rbac.authorization.k8s.io";
      }
    ];
  }) cfg.rbac;
in
{

  options.cluster.apiserver.pki = {
    enable = mkEnableOption "PKI-based authentication (client certificates)";

    namespace = mkOption {
      type = types.str;
      default = "pki-auth";
      description = "Namespace for PKI auth RBAC resources";
    };

    ca = {
      commonName = mkOption {
        type = types.str;
        default = "catallaxy-${config.cluster.name}-ca";
        description = "CA certificate Common Name";
      };

      validity = mkOption {
        type = types.str;
        default = "10y";
        description = "CA certificate validity period";
      };

      keyAlgorithm = mkOption {
        type = types.enum [
          "ecdsa-p256"
          "ecdsa-p384"
          "ed25519"
          "rsa-2048"
          "rsa-4096"
        ];
        default = "ecdsa-p256";
        description = "CA private key algorithm";
      };
    };

    defaults = {
      validity = mkOption {
        type = types.str;
        default = "1y";
        description = "Default client certificate validity";
      };

      keyAlgorithm = mkOption {
        type = types.enum [
          "ecdsa-p256"
          "ecdsa-p384"
          "ed25519"
          "rsa-2048"
          "rsa-4096"
        ];
        default = "ecdsa-p256";
        description = "Default key algorithm for client certificates";
      };

      renewBefore = mkOption {
        type = types.str;
        default = "30d";
        description = "Renew certificate this long before expiry";
      };
    };

    users = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            commonName = mkOption {
              type = types.str;
              description = ''
                Certificate Common Name. Becomes the Kubernetes username.
                Typically an email address.
              '';
            };

            organizations = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = ''
                Certificate Organization fields. These become Kubernetes groups.
                Bind these to ClusterRoles via the rbac option.
              '';
            };

            validity = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Override certificate validity for this user";
            };

            keyAlgorithm = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Override key algorithm for this user";
            };

            yubikey = {
              serialNumber = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = ''
                  YubiKey serial number for automatic provisioning.
                  When set, `cata pki provision` will target this specific device.
                '';
              };

              slot = mkOption {
                type = types.str;
                default = "9a";
                description = "PIV slot for the certificate (9a=authentication, 9c=signing)";
              };

              touchPolicy = mkOption {
                type = types.enum [
                  "always"
                  "cached"
                  "never"
                ];
                default = "always";
                description = "YubiKey touch policy (always=tap every use, cached=tap once per 15s)";
              };

              pinPolicy = mkOption {
                type = types.enum [
                  "once"
                  "always"
                  "never"
                ];
                default = "once";
                description = "YubiKey PIN policy";
              };
            };
          };
        }
      );
      default = { };
      description = "Users who receive client certificates for Kubernetes auth";
    };

    rbac = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            organization = mkOption {
              type = types.str;
              description = "Certificate Organization value (Kubernetes group name)";
            };
            clusterRole = mkOption {
              type = types.str;
              default = "cluster-admin";
              description = "ClusterRole to bind to this group";
            };
          };
        }
      );
      default = { };
      description = "Map of ClusterRoleBinding name → cert Organization → ClusterRole";
    };

    out = mkOption {
      type = types.attrs;
      readOnly = true;
      description = "Computed API-server arguments and the CA/user set the CLI consumes.";
    };
  };

  config = lib.mkMerge [
    {
      cluster.apiserver.pki.out = {
        namespace = cfg.namespace;

        clientCaPath = "/etc/kubernetes/pki/client-ca.crt";

        apiServerArgs = {
          "client-ca-file" = "/etc/kubernetes/pki/client-ca.crt";
        };

        pki = {
          ca = cfg.ca;
          defaults = cfg.defaults;
          users = mapAttrs (name: user: {
            inherit (user)
              commonName
              organizations
              validity
              keyAlgorithm
              ;
            yubikey = user.yubikey;
          }) cfg.users;
        };
      };
    }

    (mkIf (cfg.enable && cfg.rbac != { }) {
      bundles.pki-auth = {

        resources = rbacResources;

        createNamespaces = [ cfg.namespace ];
      };
    })
  ];
}

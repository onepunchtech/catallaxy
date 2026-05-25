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
  cfg = config.components.oidc;

  rbacResources = mapAttrs (name: binding: {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    metadata = {
      inherit name;
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
        name = "${cfg.groupsPrefix}${binding.group}";
        apiGroup = "rbac.authorization.k8s.io";
      }
    ];
  }) cfg.rbac;
in
{
  options.components.oidc = {
    enable = mkEnableOption "OIDC authentication for Kubernetes API server";

    phase = mkOption {
      type = types.str;
      default = "infrastructure";
      description = "Deployment phase this component belongs to";
    };

    namespace = mkOption {
      type = types.str;
      default = "kube-system";
      description = "Namespace for OIDC RBAC resources";
    };

    issuerUrl = mkOption {
      type = types.str;
      default = "";
      description = ''
        OIDC issuer URL for the Kubernetes API server.
        Use config.components.kanidm.ref.oauth2Clients.<name>.issuer
        or lab.clusters.<name>.components.kanidm.ref.oauth2Clients.<name>.issuer
        for type-safe integration.
      '';
    };

    clientId = mkOption {
      type = types.str;
      default = "kubernetes";
      description = "OIDC client ID registered in the identity provider";
    };

    usernameClaim = mkOption {
      type = types.str;
      default = "email";
      description = "JWT claim to use as the Kubernetes username";
    };

    groupsClaim = mkOption {
      type = types.str;
      default = "groups";
      description = "JWT claim containing group memberships";
    };

    usernamePrefix = mkOption {
      type = types.str;
      default = "oidc:";
      description = "Prefix added to OIDC usernames to avoid collisions";
    };

    groupsPrefix = mkOption {
      type = types.str;
      default = "oidc:";
      description = "Prefix added to OIDC groups to avoid collisions";
    };

    caSecretRef = mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            name = mkOption {
              type = types.str;
              description = "Secret name containing CA cert";
            };
            namespace = mkOption {
              type = types.str;
              description = "Secret namespace";
            };
            key = mkOption {
              type = types.str;
              default = "ca.crt";
              description = "Key within the secret";
            };
          };
        }
      );
      default = null;
      description = "Reference to Secret containing the OIDC issuer CA certificate";
    };

    rbac = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            group = mkOption {
              type = types.str;
              description = "OIDC group name (groupsPrefix will be prepended)";
            };
            clusterRole = mkOption {
              type = types.str;
              default = "cluster-admin";
              description = "ClusterRole to bind to the OIDC group";
            };
          };
        }
      );
      default = { };
      description = "Map of ClusterRoleBinding name to OIDC group + ClusterRole";
    };

    ref = mkOption {
      type = types.attrs;
      readOnly = true;
      description = "Computed references for OIDC";
    };
  };

  config = lib.mkMerge [
    {
      components.oidc.ref = {
        apiServerArgs = {
          "oidc-issuer-url" = cfg.issuerUrl;
          "oidc-client-id" = cfg.clientId;
          "oidc-username-claim" = cfg.usernameClaim;
          "oidc-groups-claim" = cfg.groupsClaim;
          "oidc-username-prefix" = cfg.usernamePrefix;
          "oidc-groups-prefix" = cfg.groupsPrefix;
        };
      };
    }

    (mkIf (cfg.enable && cfg.rbac != { }) {
      # RBAC ClusterRoleBindings
      phases.${cfg.phase}.bundles.oidc.resources = rbacResources;
    })
  ];
}

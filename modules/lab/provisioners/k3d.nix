{ config, lib, ... }:

let
  inherit (lib)
    mkOption
    mkEnableOption
    types
    mkIf
    mapAttrsToList
    ;
  oidcCfg = config.components.oidc;
  pkiCfg = config.components.pki-auth;
in
{
  options.provisioner.k3d = {
    enable = mkEnableOption "k3d provisioner (k3s-in-Docker)";

    clusterName = mkOption {
      type = types.str;
      default = config.cluster.name;
      description = "k3d cluster name";
    };

    image = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Custom k3s image (null = k3d default)";
    };

    noTraefik = mkOption {
      type = types.bool;
      default = true;
      description = "Disable default Traefik ingress";
    };

    noServiceLB = mkOption {
      type = types.bool;
      default = true;
      description = "Disable default ServiceLB (Klipper)";
    };

    noFlannel = mkOption {
      type = types.bool;
      default = true;
      description = "Disable default Flannel CNI (for Cilium)";
    };

    ports = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Port mappings for k3d (passed as -p flags).
        Format: "<host>:<container>@server:0" e.g. "8080:80@server:0"
      '';
    };

    extraApiServerArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Extra kube-apiserver arguments passed to k3d via
        --k3s-arg "--kube-apiserver-arg=<value>@server:*".
        Automatically populated from components.oidc and pki-auth.
      '';
    };

    extraVolumes = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            hostPath = mkOption {
              type = types.str;
              description = "Path on the Docker host";
            };
            containerPath = mkOption {
              type = types.str;
              description = "Path inside k3d node";
            };
          };
        }
      );
      default = [ ];
      description = "Extra volume mounts for k3d server nodes (e.g., CA certs)";
    };

    network = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Docker network to create k3d cluster on (uses --network flag). When set, all clusters share this network for cross-cluster DNS.";
    };

    autoDeployManifests = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            name = mkOption {
              type = types.str;
              description = "Manifest filename (without .yaml)";
            };
            content = mkOption {
              type = types.path;
              description = "Nix store path to rendered manifest YAML";
            };
          };
        }
      );
      default = [ ];
      description = ''
        Manifests to mount into k3s auto-deploy directory
        (/var/lib/rancher/k3s/server/manifests/). k3s applies these at boot.
        Used for pre-deploying CNI (Cilium) so nodes become Ready immediately.
      '';
    };
  };

  config.provisioner.k3d = mkIf config.provisioner.k3d.enable {
    extraApiServerArgs =
      # OIDC args
      (lib.optionals oidcCfg.enable (mapAttrsToList (k: v: "${k}=${v}") oidcCfg.ref.apiServerArgs))
      # PKI client-ca-file
      ++ (lib.optionals pkiCfg.enable (mapAttrsToList (k: v: "${k}=${v}") pkiCfg.ref.apiServerArgs));

    # Mount the CA cert into k3d nodes so the API server can trust client certs.
    # The actual file is created by `cata pki init` before cluster creation.
    extraVolumes = lib.optionals pkiCfg.enable [
      {
        hostPath = "{{STATE_DIR}}/pki/{{CLUSTER_NAME}}/ca.crt";
        containerPath = pkiCfg.ref.clientCaPath;
      }
    ];
  };
}

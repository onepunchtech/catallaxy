{ lib, ... }:

let
  inherit (lib) mkOption types;
in
{
  options.cluster = {
    name = mkOption {
      type = types.str;
      description = "Unique name for this cluster";
      example = "local";
    };

    provider = mkOption {
      type = types.enum [
        "docker"
        "crossplane"
        "external"
      ];
      default = "docker";
      description = ''
        How this cluster is provisioned:
        - docker: Talos-in-Docker (local development)
        - crossplane: Provisioned via Crossplane from another cluster
        - external: Pre-existing cluster, just configure it
      '';
    };

    kubernetes = {
      distribution = mkOption {
        type = types.enum [
          "talos"
          "k3s"
          "k8s"
        ];
        default = "talos";
        description = "Kubernetes distribution to use";
      };

      version = mkOption {
        type = types.str;
        default = "1.31";
        description = "Kubernetes API version for type generation (e.g., '1.31')";
      };

      controlPlanes = mkOption {
        type = types.ints.positive;
        default = 1;
        description = "Number of control plane nodes";
      };

      workers = mkOption {
        type = types.ints.unsigned;
        default = 1;
        description = "Number of worker nodes";
      };
    };

    talos = {
      version = mkOption {
        type = types.str;
        default = "v1.13.0";
        description = "Talos version";
      };

      cniNone = mkOption {
        type = types.bool;
        default = true;
        description = "Disable built-in CNI (for Cilium)";
      };

      kubeProxyDisabled = mkOption {
        type = types.bool;
        default = true;
        description = "Disable kube-proxy (for Cilium kube-proxy replacement)";
      };
    };

    network = {
      podSubnet = mkOption {
        type = types.str;
        default = "10.244.0.0/16";
        description = "Pod network CIDR";
      };

      serviceSubnet = mkOption {
        type = types.str;
        default = "10.96.0.0/12";
        description = "Service network CIDR";
      };
    };

    certSANs = mkOption {
      type = types.listOf types.str;
      default = [
        "127.0.0.1"
        "localhost"
      ];
      description = ''
        Extra Subject Alternative Names added to CAPI cluster API server certificates.
        Includes 127.0.0.1 so kubeconfigs rewritten for host access work with valid TLS.
      '';
    };
  };
}

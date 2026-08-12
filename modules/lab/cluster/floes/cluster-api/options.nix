{
  lib,
  config,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption mkDefault types;

  cidrFirstIP =
    cidr:
    let
      network = lib.head (lib.splitString "/" cidr);
      octets = map lib.strings.toInt (lib.splitString "." network);
      firstIP = lib.init octets ++ [ ((lib.last octets) + 1) ];
    in
    lib.concatStringsSep "." (map toString firstIP);

  workerPoolType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
      };
      replicas = mkOption {
        type = types.int;
        default = 3;
      };
      machineType = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      labels = mkOption {
        type = types.attrsOf types.str;
        default = { };
      };
      taints = mkOption {
        type = types.listOf (
          types.submodule {
            options = {
              key = mkOption { type = types.str; };
              value = mkOption {
                type = types.str;
                default = "";
              };
              effect = mkOption {
                type = types.enum [
                  "NoSchedule"
                  "PreferNoSchedule"
                  "NoExecute"
                ];
              };
            };
          }
        );
        default = [ ];
      };
    };
  };

  capiClusterType = types.submodule (
    { config, ... }:
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = true;
        };
        ref = mkOption {
          type = types.attrs;
          readOnly = true;
        };
        infrastructureProvider = mkOption {
          type = types.enum [
            "docker"
            "digitalocean"
            "hetzner"
            "aws"
            "gcp"
            "azure"
            "vsphere"
          ];
        };
        kubernetes = {
          version = mkOption {
            type = types.str;
            default = "v1.31.0";
          };
          controlPlane = {
            replicas = mkOption {
              type = types.int;
              default = 3;
            };
            machineType = mkOption {
              type = types.nullOr types.str;
              default = null;
            };
          };
          workers = mkOption {
            type = types.listOf workerPoolType;
            default = [
              {
                name = "default";
                replicas = 3;
              }
            ];
          };
        };
        talos = {
          enable = mkOption {
            type = types.bool;
            default = true;
          };
          version = mkOption {
            type = types.str;
            default = "v1.8.0";
          };
        };
        network = {
          podCIDR = mkOption {
            type = types.str;
            default = "10.244.0.0/16";
          };
          serviceCIDR = mkOption {
            type = types.str;
            default = "10.96.0.0/12";
          };
        };
        digitalocean = {
          region = mkOption {
            type = types.str;
            default = "nyc1";
          };
          controlPlaneSize = mkOption {
            type = types.str;
            default = "s-2vcpu-4gb";
          };
          workerSize = mkOption {
            type = types.str;
            default = "s-2vcpu-4gb";
          };
          sshKeys = mkOption {
            type = types.listOf types.str;
            default = [ ];
          };
          image = mkOption {
            type = types.str;
            default = "ubuntu-24-04-x64";
          };
        };
        hetzner = {
          region = mkOption {
            type = types.str;
            default = "fsn1";
          };
          controlPlaneType = mkOption {
            type = types.str;
            default = "cpx31";
          };
          workerType = mkOption {
            type = types.str;
            default = "cpx31";
          };
          sshKeyName = mkOption {
            type = types.nullOr types.str;
            default = null;
          };
          placementGroup = mkOption {
            type = types.bool;
            default = true;
          };
          network = {
            enabled = mkOption {
              type = types.bool;
              default = true;
            };
            cidr = mkOption {
              type = types.str;
              default = "10.0.0.0/8";
            };
          };
        };
        certSANs = mkOption {
          type = types.listOf types.str;
          default = [ ];
        };
        apiServerExtraArgs = mkOption {
          type = types.attrsOf types.str;
          default = { };
        };
        clientCaCert = mkOption {
          type = types.nullOr types.str;
          default = null;
        };
        registryMirror = {
          enable = mkOption {
            type = types.bool;
            default = false;
          };
          endpoint = mkOption {
            type = types.str;
            default = "http://172.17.0.1:5050";
          };
          registries = mkOption {
            type = types.listOf types.str;
            default = [
              "docker.io"
              "ghcr.io"
              "quay.io"
              "registry.k8s.io"
            ];
          };
        };
        docker = {
          loadBalancerImage = mkOption {
            type = types.str;
            default = "kindest/haproxy:v20230606-42a2262b";
          };
        };
        aws = {
          region = mkOption {
            type = types.str;
            default = "us-east-1";
          };
          sshKeyName = mkOption {
            type = types.nullOr types.str;
            default = null;
          };
          controlPlaneInstanceType = mkOption {
            type = types.str;
            default = "t3.large";
          };
          workerInstanceType = mkOption {
            type = types.str;
            default = "t3.large";
          };
        };
      };

      config.ref = {
        kubernetesServiceIP = cidrFirstIP config.network.serviceCIDR;
        kubernetesServicePort = "443";
        serviceCIDR = config.network.serviceCIDR;
        podCIDR = config.network.podCIDR;
      };
    }
  );
in
{
  config.floes.cluster-api.namespace = mkDefault "capi-system";

  options.floes.cluster-api = {
    chart = mkOption {
      type = types.package;
      default = cataCharts.capi-operator.chart;
    };

    isManagementCluster = mkOption {
      type = types.bool;
      default = false;
    };

    infrastructureProviders = mkOption {
      type = types.listOf (
        types.enum [
          "docker"
          "digitalocean"
          "aws"
          "gcp"
          "azure"
          "hetzner"
          "vsphere"
        ]
      );
      default = [ ];
    };

    bootstrapProviders = mkOption {
      type = types.listOf (
        types.enum [
          "kubeadm"
          "talos"
        ]
      );
      default = [ "talos" ];
    };

    controlPlaneProviders = mkOption {
      type = types.listOf (
        types.enum [
          "kubeadm"
          "talos"
        ]
      );
      default = [ "talos" ];
    };

    providerVersions = {
      core = mkOption {
        type = types.str;
        default = "1.13.2";
      };
      talosBootstrap = mkOption {
        type = types.str;
        default = "0.6.7";
      };
      talosControlPlane = mkOption {
        type = types.str;
        default = "0.5.13";
      };
      docker = mkOption {
        type = types.str;
        default = "1.9.0";
      };
      hetzner = mkOption {
        type = types.str;
        default = "1.0.0-beta.40";
      };
      digitalocean = mkOption {
        type = types.str;
        default = "1.6.0";
      };
      aws = mkOption {
        type = types.str;
        default = "2.7.0";
      };
    };

    clusters = mkOption {
      type = types.attrsOf capiClusterType;
      default = { };
    };
  };
}

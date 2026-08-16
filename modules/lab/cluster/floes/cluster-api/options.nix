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
        description = "Name of this worker pool.";
      };
      replicas = mkOption {
        type = types.int;
        default = 3;
        description = "How many machines it holds.";
      };
      machineType = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Provider machine type for its nodes. Null takes the per-provider default below.";
      };
      labels = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Node labels applied to every machine in the pool.";
      };
      taints = mkOption {
        type = types.listOf (
          types.submodule {
            options = {
              key = mkOption {
                type = types.str;
                description = "Taint key.";
              };
              value = mkOption {
                type = types.str;
                default = "";
                description = "Taint value.";
              };
              effect = mkOption {
                type = types.enum [
                  "NoSchedule"
                  "PreferNoSchedule"
                  "NoExecute"
                ];
                description = "What the taint does to a pod that does not tolerate it.";
              };
            };
          }
        );
        default = [ ];
        description = "Taints applied to every machine, so only tolerating workloads land here.";
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
          description = "Declare this cluster. Off keeps the declaration without provisioning it.";
        };
        ref = mkOption {
          type = types.attrs;
          readOnly = true;
          description = "Reference to the cluster this one is a part of.";
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
          description = "Which infrastructure provider stands the cluster up. This decides which of the per-provider blocks below applies.";
        };
        kubernetes = {
          version = mkOption {
            type = types.str;
            default = "v1.31.0";
            description = "Kubernetes version for the cluster.";
          };
          controlPlane = {
            replicas = mkOption {
              type = types.int;
              default = 3;
              description = "How many control plane machines to run. Three is the smallest that tolerates losing one.";
            };
            machineType = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Machine type for control plane nodes. Null takes the per-provider default.";
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
            description = "Worker pools to create.";
          };
        };
        talos = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Install a CNI. Off leaves the cluster without pod networking until something else provides it.";
          };
          version = mkOption {
            type = types.str;
            default = "v1.8.0";
            description = "Version of the CNI to install.";
          };
        };
        network = {
          podCIDR = mkOption {
            type = types.str;
            default = "10.244.0.0/16";
            description = "CIDR pods get addresses from.";
          };
          serviceCIDR = mkOption {
            type = types.str;
            default = "10.96.0.0/12";
            description = "CIDR Services get addresses from.";
          };
        };
        digitalocean = {
          region = mkOption {
            type = types.str;
            default = "nyc1";
            description = "DigitalOcean region slug.";
          };
          controlPlaneSize = mkOption {
            type = types.str;
            default = "s-2vcpu-4gb";
            description = "Size slug for control plane nodes.";
          };
          workerSize = mkOption {
            type = types.str;
            default = "s-2vcpu-4gb";
            description = "Size slug for worker nodes.";
          };
          sshKeys = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Names of SSH keys already in the account to install.";
          };
          image = mkOption {
            type = types.str;
            default = "ubuntu-24-04-x64";
            description = "Image slug to boot from.";
          };
        };
        hetzner = {
          region = mkOption {
            type = types.str;
            default = "fsn1";
            description = "Hetzner location.";
          };
          controlPlaneType = mkOption {
            type = types.str;
            default = "cpx31";
            description = "Server type for control plane nodes.";
          };
          workerType = mkOption {
            type = types.str;
            default = "cpx31";
            description = "Server type for worker nodes.";
          };
          sshKeyName = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "SSH key already in the Hetzner project to install. Null installs none.";
          };
          placementGroup = mkOption {
            type = types.bool;
            default = true;
            description = "Spread machines across failure domains with a placement group.";
          };
          network = {
            enabled = mkOption {
              type = types.bool;
              default = true;
              description = "Attach machines to a private network.";
            };
            cidr = mkOption {
              type = types.str;
              default = "10.0.0.0/8";
              description = "CIDR for that network.";
            };
          };
        };
        certSANs = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Extra names to put in the API server certificate, for reaching it by a name it does not know about.";
        };
        apiServerExtraArgs = mkOption {
          type = types.attrsOf types.str;
          default = { };
          description = "Extra flags for the API server.";
        };
        clientCaCert = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "CA certificate to trust for client certificates, when clients are issued by something other than the cluster.";
        };
        registryMirror = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = "Point the cluster at a pull-through registry mirror.";
          };
          endpoint = mkOption {
            type = types.str;
            default = "http://172.17.0.1:5050";
            description = "Address of that mirror.";
          };
          registries = mkOption {
            type = types.listOf types.str;
            default = [
              "docker.io"
              "ghcr.io"
              "quay.io"
              "registry.k8s.io"
            ];
            description = "Upstream registries the mirror stands in for.";
          };
        };
        docker = {
          loadBalancerImage = mkOption {
            type = types.str;
            default = "kindest/haproxy:v20230606-42a2262b";
            description = "HAProxy image used as the load balancer in front of the control plane.";
          };
        };
        aws = {
          region = mkOption {
            type = types.str;
            default = "us-east-1";
            description = "AWS region.";
          };
          sshKeyName = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "EC2 key pair to install. Null installs none.";
          };
          controlPlaneInstanceType = mkOption {
            type = types.str;
            default = "t3.large";
            description = "Instance type for control plane nodes.";
          };
          workerInstanceType = mkOption {
            type = types.str;
            default = "t3.large";
            description = "Instance type for worker nodes.";
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
      description = "Helm chart to install. Defaults to the chart catallaxy pins.";
    };

    isManagementCluster = mkOption {
      type = types.bool;
      default = false;
      description = "Whether this cluster runs the Cluster API controllers themselves. A cluster that manages itself is what triggers a pivot.";
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
      description = "Infrastructure providers to install controllers for.";
    };

    bootstrapProviders = mkOption {
      type = types.listOf (
        types.enum [
          "kubeadm"
          "talos"
        ]
      );
      default = [ "talos" ];
      description = "Bootstrap providers, which turn a machine into a cluster member.";
    };

    controlPlaneProviders = mkOption {
      type = types.listOf (
        types.enum [
          "kubeadm"
          "talos"
        ]
      );
      default = [ "talos" ];
      description = "Control plane providers, which manage the control plane's lifecycle.";
    };

    providerVersions = {
      core = mkOption {
        type = types.str;
        default = "1.13.2";
        description = "Version of the core Cluster API controllers.";
      };
      talosBootstrap = mkOption {
        type = types.str;
        default = "0.6.7";
        description = "Version of the Talos bootstrap provider.";
      };
      talosControlPlane = mkOption {
        type = types.str;
        default = "0.5.13";
        description = "Version of the Talos control plane provider.";
      };
      docker = mkOption {
        type = types.str;
        default = "1.9.0";
        description = "Version of the Docker infrastructure provider.";
      };
      hetzner = mkOption {
        type = types.str;
        default = "1.0.0-beta.40";
        description = "Version of the Hetzner provider.";
      };
      digitalocean = mkOption {
        type = types.str;
        default = "1.6.0";
        description = "Version of the DigitalOcean provider.";
      };
      aws = mkOption {
        type = types.str;
        default = "2.7.0";
        description = "Version of the AWS provider.";
      };
    };

    clusters = mkOption {
      type = types.attrsOf capiClusterType;
      default = { };
      description = "Clusters to declare through Cluster API.";
    };
  };
}

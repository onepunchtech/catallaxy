{ config, lib, ... }:

let
  inherit ((import ../../../lib/floe { inherit lib; })) labFloeOptions;

  cfg = config.lab.floes.talos-local;
in
{
  imports = [ (labFloeOptions { name = "talos-local"; }) ];

  options.lab.floes.talos-local.exports = {
    clusters = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Clusters this platform stood up, for a floe layered on top to reach the same set.";
    };
  };

  options.lab.floes.talos-local = {
    clusters = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [ "app" ];
      description = "Clusters this platform provisions, each set to the talos provisioner.";
    };

    workers = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 1;
      description = ''
        Worker nodes each cluster gets.

        At least one, unless nothing has to be scheduled. A Talos control
        plane keeps the standard NoSchedule taint, unlike a k3d server node,
        so a cluster with no workers has nowhere to run a workload.

        This wins over whatever the lab asked for, because the lab is stating
        a preference and this is stating what the platform can do. Set it here
        rather than on the cluster.
      '';
    };

    kubernetesVersion = lib.mkOption {
      type = lib.types.str;
      default = "1.32.5";
      description = ''
        Kubelet image tag, written major.minor.patch.

        Distinct from `cluster.kubernetes.version`, which is the schema set
        the manifests are typed against and is written major.minor. That one
        is not a tag anything can pull.
      '';
    };

    subnet = lib.mkOption {
      type = lib.types.str;
      default = "10.6.0.0/24";
      description = ''
        Subnet talosctl makes for the cluster's own network.

        Talos gets its own, because talosctl will not join one it did not
        make. Must not overlap any lab's `dockerSubnet`, and the lab reaches
        into it rather than the cluster joining the lab's network.
      '';
    };

    dockerSubnet = lib.mkOption {
      type = lib.types.str;
      default = "172.25.0.0/16";
      description = "Subnet for the lab's own docker network, where its services live.";
    };

    hostPorts = lib.mkOption {
      type = lib.types.submodule {
        options = {
          proxy = lib.mkOption {
            type = lib.types.port;
            default = 8080;
            description = "Host port the lab's HAProxy answers on.";
          };
          registry = lib.mkOption {
            type = lib.types.port;
            default = 5051;
            description = "Host port the lab's registry answers on.";
          };
          egress = lib.mkOption {
            type = lib.types.port;
            default = 3129;
            description = "Host port the lab's forward proxy answers on.";
          };
          dns = lib.mkOption {
            type = lib.types.port;
            default = 5356;
            description = "Host port the lab's DNS answers on.";
          };
        };
      };
      default = { };
      description = ''
        Ports this lab's services take on the host.

        Given on purpose and distinct from the framework's defaults, because
        the labs this platform stands up are meant to run beside a k3d one.
        `lab-host-ports` checks they stay distinct.
      '';
    };

    tls = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether the lab's ingress terminates TLS.";
    };
  };

  config = lib.mkIf cfg.enable {
    lab.network.dockerSubnet = lib.mkDefault cfg.dockerSubnet;

    lab.dns.enable = lib.mkDefault true;
    lab.registry.enable = lib.mkDefault true;
    lab.proxy.enable = lib.mkDefault true;
    lab.proxy.tls.enable = lib.mkDefault cfg.tls;

    lab.proxy.httpPort = lib.mkDefault cfg.hostPorts.proxy;
    lab.registry.port = lib.mkDefault cfg.hostPorts.registry;
    lab.egress.port = lib.mkDefault cfg.hostPorts.egress;
    lab.dns.hostPort = lib.mkDefault cfg.hostPorts.dns;

    lab.floes.talos-local.exports.clusters = cfg.clusters;

    lab.clusters =
      lib.genAttrs (lib.subtractLists config.lab.platforms.contestedClusters cfg.clusters)
        (_: {
          cluster.provisioner = lib.mkDefault "talos";

          cluster.kubernetes.workers = lib.mkForce cfg.workers;

          provisioner.talos = {
            subnet = lib.mkDefault cfg.subnet;
            kubernetesVersion = lib.mkDefault cfg.kubernetesVersion;
          };
        });
  };
}

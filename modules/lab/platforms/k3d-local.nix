{ config, lib, ... }:

let
  inherit ((import ../../../lib/floe { inherit lib; })) labFloeOptions;

  cfg = config.lab.floes.k3d-local;
in
{
  imports = [ (labFloeOptions { name = "k3d-local"; }) ];

  options.lab.floes.k3d-local.exports = {
    clusters = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Clusters this platform stood up, for a floe layered on top to reach the same set.";
    };
  };

  options.lab.floes.k3d-local = {
    clusters = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [ "app" ];
      description = ''
        Clusters this platform provisions. Each named cluster is set to the
        k3d provisioner and given this platform's k3s image and network.

        A cluster the lab declares and this list omits is left alone, which
        is how a lab runs two platforms side by side.
      '';
    };

    image = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "rancher/k3s:v1.31.4-k3s1";
      description = "k3s image k3d runs. Null takes k3d's own default, which moves when k3d does.";
    };

    network = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Docker network the clusters join, where this platform means to move
        them off the lab's own.

        Null leaves `provisioner.k3d.network` alone, and that already
        defaults to the lab's network, which is where its DNS, registry and
        ingress are. Saying it twice is how the two come to disagree.

        A cluster on any other network cannot reach those: nothing fails at
        creation, and the symptom is every lab address timing out from inside
        the cluster. To give a cluster its own on purpose, set
        `provisioner.k3d.network = null` on that cluster.
      '';
    };

    dockerSubnet = lib.mkOption {
      type = lib.types.str;
      default = "172.20.0.0/16";
      description = ''
        Subnet for the lab's docker network.

        Distinct per lab, so two labs can be up at once. `lab-host-ports`
        checks the ports; nothing checks this, so it is given on purpose.
      '';
    };

    hostPorts = lib.mkOption {
      type = lib.types.submodule {
        options =
          lib.genAttrs
            [
              "proxy"
              "registry"
              "egress"
              "dns"
            ]
            (
              service:
              lib.mkOption {
                type = lib.types.nullOr lib.types.port;
                default = null;
                description = "Host port the lab's ${service} answers on. Null leaves the framework's own default.";
              }
            );
      };
      default = { };
      description = ''
        Ports this lab's services take on the host, where this platform means
        to move them.

        Null throughout, so the framework's defaults stand and are stated in
        one place. Everything else about a lab is named after it and cannot
        collide; these are the one thing a second lab has to be given on
        purpose.
      '';
    };

    tls = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether the lab's ingress terminates TLS.

        Off for local development, where the certificate would be one no
        browser or client on the host trusts without being told to.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    lab.network.dockerSubnet = lib.mkDefault cfg.dockerSubnet;

    lab.dns.enable = lib.mkDefault true;
    lab.registry.enable = lib.mkDefault true;
    lab.proxy.enable = lib.mkDefault true;
    lab.proxy.tls.enable = lib.mkDefault cfg.tls;

    lab.proxy.httpPort = lib.mkIf (cfg.hostPorts.proxy != null) (lib.mkDefault cfg.hostPorts.proxy);
    lab.registry.port = lib.mkIf (cfg.hostPorts.registry != null) (
      lib.mkDefault cfg.hostPorts.registry
    );
    lab.egress.port = lib.mkIf (cfg.hostPorts.egress != null) (lib.mkDefault cfg.hostPorts.egress);
    lab.dns.hostPort = lib.mkIf (cfg.hostPorts.dns != null) (lib.mkDefault cfg.hostPorts.dns);

    lab.floes.k3d-local.exports.clusters = cfg.clusters;

    lab.clusters =
      lib.genAttrs (lib.subtractLists config.lab.platforms.contestedClusters cfg.clusters)
        (_: {
          cluster.provisioner = lib.mkDefault "k3d";

          provisioner.k3d = {
            image = lib.mkDefault cfg.image;
            network = lib.mkIf (cfg.network != null) (lib.mkDefault cfg.network);

            noTraefik = lib.mkDefault true;

            noServiceLB = lib.mkDefault false;
          };
        });
  };
}

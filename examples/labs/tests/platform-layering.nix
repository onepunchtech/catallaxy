{ config, lib, ... }:

let
  inherit ((import ../../../lib/floe { inherit lib; })) labFloeOptions;

  # Written here rather than under `modules/lab/platforms` on purpose: a
  # platform floe an operator writes lives in their own repo, and `mkLab`
  # takes arbitrary modules, so there is no registry to add it to. If this
  # ever needs one, this fixture stops evaluating.
  k3d-isolated =
    { config, ... }:
    let
      cfg = config.lab.floes.k3d-isolated;
    in
    {
      imports = [ (labFloeOptions { name = "k3d-isolated"; }) ];

      options.lab.floes.k3d-isolated.clusters = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Clusters this platform provisions, handed straight to the base it builds on.";
      };

      config = lib.mkIf cfg.enable {
        # Everything this variant changes it changes through the base's own
        # options. That is the layering claim: a floe builds on another by
        # configuring it, not by fighting it.
        lab.floes.k3d-local = {
          enable = true;
          inherit (cfg) clusters;

          hostPorts.registry = 5099;
          hostPorts.dns = 5399;
        };

        # And where it has to override what the base decided rather than what
        # the base was asked, the base's `mkDefault` yields to a plain
        # assignment. No `mkForce` anywhere in this file is the test.
        lab.proxy.enable = false;

        lab.clusters = lib.genAttrs cfg.clusters (_: {
          provisioner.k3d.network = null;
        });
      };
    };
in
{
  imports = [ k3d-isolated ];

  lab.name = "platform-layering";
  lab.environment = "development";
  lab.dns.zone = "layering.test";

  lab.floes.k3d-isolated = {
    enable = true;
    clusters = [ "app" ];
  };

  lab.clusters.app = {
    cluster.name = "app";
    cluster.kubernetes = {
      distribution = "k3s";
      controlPlanes = 1;
      workers = 0;
    };
  };

  # The layering claim, checked rather than described. A lab that fails one of
  # these does not evaluate, so the digest check fails with the reason.
  lab.assertions = [
    {
      assertion = config.lab.clusters.app.cluster.provisioner == "k3d";
      message = "the base floe did not reach the cluster: provisioner is '${config.lab.clusters.app.cluster.provisioner}', not k3d";
    }
    {
      assertion = config.lab.registry.enable;
      message = "the base floe's `lab.registry.enable` did not survive the variant";
    }
    {
      assertion = config.lab.registry.port == 5099;
      message = "the variant configured the base and lost: registry port is ${toString config.lab.registry.port}, not 5099";
    }
    {
      assertion = config.lab.dns.hostPort == 5399;
      message = "the variant configured the base and lost: dns host port is ${toString config.lab.dns.hostPort}, not 5399";
    }
    {
      assertion = config.lab.clusters.app.provisioner.k3d.network == null;
      message = "the variant asked the base for its own docker network and the base's default won instead";
    }
    {
      assertion = !config.lab.proxy.enable;
      message = "the base's `mkDefault true` beat the variant's plain `false`, so the base is overriding rather than defaulting";
    }
  ];
}

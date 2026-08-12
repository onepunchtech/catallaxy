{ config, lab, ... }:
{
  imports = [
    ../aspects/identity.nix
    ../aspects/mesh.nix
  ];

  cluster.kubernetes = {
    distribution = "k3s";
    controlPlanes = 1;
    workers = 0;
  };

  floes.cert-manager = {
    enable = true;
    selfSignedCA.enable = true;
  };
  floes.trust-manager.enable = true;
  floes.reloader.enable = true;

  floes.gateway = {
    enable = true;

    internal = {
      enable = true;
      exposureMode = "netbird";
      clusterIPAddress = "10.96.100.100";
    };
  };

  floes.custom.enable = true;
  floes.custom.apps.ops = {
    namespace = "ops";
    gateway = {
      enable = true;
      tier = "internal";
      domain = "ops.${lab.dns.internalZone}";
      serviceName = "ops";
      servicePort = 80;
    };
    resources = import ../lib/demo-site.nix {
      name = "ops";
      namespace = "ops";
      domain = "ops.${lab.dns.internalZone}";
      cluster = "management cluster";
      accent = "#a78bfa";
      gatewayIP = config.floes.gateway.internal.clusterIPAddress;
    };
  };
}

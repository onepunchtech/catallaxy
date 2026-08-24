{ ... }:
{
  lab.name = "infra.local";
  lab.environment = "development";

  lab.network.dockerSubnet = "172.26.0.0/16";

  # This lab is about provisioning, not ingress. Turning the host services off
  # keeps it off every port another lab wants, so it can run beside them.
  lab.dns.enable = false;
  lab.registry.enable = false;
  lab.proxy.enable = false;

  lab.floes.k3d-local = {
    enable = true;
    clusters = [ "app" ];
  };
}

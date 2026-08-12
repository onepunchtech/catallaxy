{ ... }:
{
  lab.name = "minimal.local";
  lab.environment = "development";

  lab.network.dockerSubnet = "172.20.0.0/16";

  lab.dns.enable = true;
  lab.registry.enable = true;
  lab.proxy.enable = true;

  lab.proxy.tls.enable = false;

  lab.clusters.app =
    { lab, ... }:
    {
      cluster.provisioner = "k3d";
      provisioner.k3d = {
        image = "rancher/k3s:v1.31.4-k3s1";
        network = lab.name;

        noTraefik = true;

        noServiceLB = false;
      };
    };
}

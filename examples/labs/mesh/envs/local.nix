{ ... }:
{
  lab.name = "mesh.local";
  lab.environment = "development";

  lab.network.dockerSubnet = "172.21.0.0/16";

  lab.dns.enable = true;
  lab.dns.configureHost = true;
  lab.registry.enable = true;
  lab.proxy.enable = true;

  lab.clusters.mgmt =
    { lab, ... }:
    {
      imports = [ ../provisioners/k3d.nix ];
      provisioner.k3d.network = lab.name;
    };

  lab.clusters.apps =
    { lab, ... }:
    {
      imports = [ ../provisioners/k3d.nix ];
      provisioner.k3d.network = lab.name;
    };
}

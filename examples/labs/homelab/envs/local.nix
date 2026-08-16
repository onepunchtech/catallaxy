{ ... }:
{
  lab.name = "homelab.local";
  lab.environment = "development";

  lab.secrets.envFile = "examples/labs/homelab/envs/ci.env";

  lab.network.dockerSubnet = "172.22.0.0/16";

  lab.dns.enable = true;
  lab.dns.configureHost = true;
  lab.registry.enable = true;
  lab.proxy.enable = true;

  lab.clusters.core =
    { lab, ... }:
    {
      imports = [ ../provisioners/k3d.nix ];
      provisioner.k3d.network = lab.name;
    };
  lab.clusters.obs =
    { lab, ... }:
    {
      imports = [ ../provisioners/k3d.nix ];
      provisioner.k3d.network = lab.name;
    };
}

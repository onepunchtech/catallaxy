{ ... }:
{
  lab.name = "homelab.local";

  # Its own host ports, so this lab can be up beside another. Everything
  # else is already named after the lab; the ports are the one thing that
  # has to be given on purpose. `lab-host-ports` checks they stay distinct.
  lab.proxy.httpPort = 8082;
  lab.proxy.httpsPort = 9444;
  lab.registry.port = 5053;
  lab.egress.port = 3131;
  lab.dns.hostPort = 5358;
  lab.environment = "development";

  lab.secrets.envFile = "examples/labs/homelab/envs/ci.env";

  lab.network.dockerSubnet = "172.22.0.0/16";

  lab.dns.enable = true;
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

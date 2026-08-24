{ ... }:
{
  lab.name = "mesh.local";

  # Its own host ports, so this lab can be up beside another. Everything
  # else is already named after the lab; the ports are the one thing that
  # has to be given on purpose. `lab-host-ports` checks they stay distinct.
  lab.proxy.httpPort = 8081;
  lab.proxy.httpsPort = 9443;
  lab.registry.port = 5052;
  lab.egress.port = 3130;
  lab.dns.hostPort = 5357;
  lab.environment = "development";

  lab.network.dockerSubnet = "172.21.0.0/16";

  lab.dns.enable = true;
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

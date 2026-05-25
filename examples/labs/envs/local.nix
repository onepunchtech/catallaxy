# Local development — all k3d, no CAPI
{ ... }:
{
  lab.name = "homelab.local";
  lab.environment = "development";

  lab.dns.enable = true;
  lab.registry.enable = true;
  lab.ingress.enable = true;

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

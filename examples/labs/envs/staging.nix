# Staging — k3d but with HA and production-like settings
{ ... }:
{
  lab.name = "homelab.staging";
  lab.environment = "staging";

  lab.dns.enable = true;
  lab.registry.enable = true;
  lab.proxy.enable = true;

  lab.clusters.core =
    { ... }:
    {
      imports = [ ../provisioners/k3d.nix ];
      components.argocd.ha = true;
    };
  lab.clusters.obs =
    { ... }:
    {
      imports = [ ../provisioners/k3d.nix ];
      components.otel-collector.gateway.replicas = 3;
    };
}

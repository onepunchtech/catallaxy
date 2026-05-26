# Production — mgmt cluster + CAPI on DigitalOcean
{ lib, ... }:
{
  lab.name = "homelab.prod";
  lab.environment = "production";

  # Mgmt cluster provisions cloud clusters via CAPI
  lab.clusters.mgmt =
    { ... }:
    {
      imports = [
        ../clusters/mgmt.nix
        ../provisioners/k3d.nix
      ];
      components.cluster-api.infrastructureProviders = [ "digitalocean" ];
      components.crossplane.providers = [
        "digitalocean"
        "cloudflare"
      ];
    };

  lab.clusters.core =
    { ... }:
    {
      cluster.provisioner = lib.mkForce "external";
      components.argocd.ha = true;
      components.cnpg.clusters.postgres.instances = lib.mkForce 2;
      components.cnpg.clusters.postgres.storage.size = lib.mkForce "20Gi";
    };

  lab.clusters.obs =
    { ... }:
    {
      cluster.provisioner = lib.mkForce "external";
      components.otel-collector.gateway.replicas = 3;
    };
}

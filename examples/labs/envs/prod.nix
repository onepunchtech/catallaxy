# Production — mgmt cluster + DOKS on DigitalOcean via Crossplane
{ lib, ... }:
{
  lab.name = "homelab.prod";
  lab.environment = "production";

  # Secret stores — each becomes one SOPS file
  lab.secrets.stores.cloud-creds = { backend = "sops"; };

  # Managed secrets — source of truth for credential values
  lab.secrets.managed = {
    do-token = {
      store = "cloud-creds";
      keys.token = { };
    };
    cf-token = {
      store = "cloud-creds";
      keys.token = { };
    };
  };

  # Mgmt cluster provisions DOKS clusters via Crossplane
  lab.clusters.mgmt =
    { ... }:
    {
      imports = [
        ../clusters/mgmt.nix
        ../provisioners/k3d.nix
      ];
      components.crossplane.providers = [
        "digitalocean"
        "cloudflare"
      ];

      # DOKS managed Kubernetes clusters on DigitalOcean
      components.crossplane.digitalocean.kubernetesClusters = {
        core = {
          region = "nyc1";
          version = "1.36.0-do.0";
          nodePool = {
            name = "default";
            size = "s-4vcpu-8gb";
            nodeCount = 2;
          };
        };

        obs = {
          region = "nyc1";
          version = "1.36.0-do.0";
          nodePool = {
            name = "default";
            size = "s-2vcpu-4gb";
            nodeCount = 1;
          };
        };
      };
    };

  lab.clusters.core =
    { ... }:
    {
      cluster.provisioner = lib.mkForce "crossplane";
      components.argocd.ha = true;
      components.cnpg.clusters.postgres.instances = lib.mkForce 2;
      components.cnpg.clusters.postgres.storage.size = lib.mkForce "20Gi";
    };

  lab.clusters.obs =
    { ... }:
    {
      cluster.provisioner = lib.mkForce "crossplane";
      components.otel-collector.gateway.replicas = 3;
    };
}

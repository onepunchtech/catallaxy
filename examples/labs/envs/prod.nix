# Production — mgmt cluster + CAPI on DigitalOcean
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

      # CAPI-managed workload clusters on DigitalOcean
      components.cluster-api.clusters = {
        core = {
          infrastructureProvider = "digitalocean";
          kubernetes.version = "v1.31.0";
          kubernetes.controlPlane.replicas = 1;
          kubernetes.workers = [
            {
              name = "default";
              replicas = 2;
            }
          ];
          talos.enable = false;
          digitalocean = {
            region = "nyc1";
            controlPlaneSize = "s-2vcpu-4gb";
            workerSize = "s-4vcpu-8gb";
          };
        };

        obs = {
          infrastructureProvider = "digitalocean";
          kubernetes.version = "v1.31.0";
          kubernetes.controlPlane.replicas = 1;
          kubernetes.workers = [
            {
              name = "default";
              replicas = 1;
            }
          ];
          talos.enable = false;
          digitalocean = {
            region = "nyc1";
            controlPlaneSize = "s-2vcpu-4gb";
            workerSize = "s-2vcpu-4gb";
          };
        };
      };
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

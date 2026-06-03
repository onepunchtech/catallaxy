# Production — mgmt cluster + DOKS on DigitalOcean via Crossplane
{ lib, ... }:
{
  lab.name = "homelab.prod";
  lab.environment = "production";
  lab.dns.zone = "lab.praxioticsystems.com";

  # Secret stores — each becomes one SOPS file
  lab.secrets.stores.cloud-creds = {
    backend = "sops";
  };

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
            nodeCount = 2;
          };
        };
      };
    };

  lab.clusters.core =
    { ... }:
    {
      cluster.provisioner = lib.mkForce "crossplane";

      # Use Let's Encrypt for TLS on production clusters
      components.cert-manager.selfSignedCA.enable = lib.mkForce false;
      components.cert-manager.acme = {
        enable = true;
        email = "admin@praxioticsystems.com";
        dns01.provider = "cloudflare";
      };

      # Project CF token into cert-manager namespace for ACME DNS01.
      # Must be in operators phase — cert-manager ClusterIssuer needs it in infrastructure.
      secrets.projections.cloudflare-api-token = {
        source = "cf-token";
        namespace = "cert-manager";
        phase = "operators";
        keys.api-token.from = "token";
      };

      # ExternalDNS via Cloudflare (overrides local RFC2136 from networking aspect)
      components.external-dns = {
        enable = lib.mkForce true;
        domainFilters = [ "praxioticsystems.com" ];
        env = [
          {
            name = "CF_API_TOKEN";
            valueFrom.secretKeyRef = {
              name = "cloudflare-extdns-token";
              key = "api-token";
            };
          }
        ];
      };

      # Project CF token into external-dns namespace (before external-dns deploys)
      secrets.projections.cloudflare-extdns-token = {
        source = "cf-token";
        namespace = "external-dns";
        phase = "operators";
        keys.api-token.from = "token";
      };

      components.argocd.ha = true;
      components.cnpg.clusters.postgres.instances = lib.mkForce 2;
      components.cnpg.clusters.postgres.storage.size = lib.mkForce "20Gi";
    };

  lab.clusters.obs =
    { ... }:
    {
      cluster.provisioner = lib.mkForce "crossplane";

      # Use Let's Encrypt for TLS on production clusters
      components.cert-manager.selfSignedCA.enable = lib.mkForce false;
      components.cert-manager.acme = {
        enable = true;
        email = "admin@praxioticsystems.com";
        dns01.provider = "cloudflare";
      };

      # Project CF token into cert-manager namespace (operators phase — before ACME issuer)
      secrets.projections.cloudflare-api-token = {
        source = "cf-token";
        namespace = "cert-manager";
        phase = "operators";
        keys.api-token.from = "token";
      };

      # ExternalDNS via Cloudflare (overrides local RFC2136 from networking aspect)
      components.external-dns = {
        enable = lib.mkForce true;
        domainFilters = [ "praxioticsystems.com" ];
        env = [
          {
            name = "CF_API_TOKEN";
            valueFrom.secretKeyRef = {
              name = "cloudflare-extdns-token";
              key = "api-token";
            };
          }
        ];
      };

      # Project CF token into external-dns namespace (before external-dns deploys)
      secrets.projections.cloudflare-extdns-token = {
        source = "cf-token";
        namespace = "external-dns";
        phase = "operators";
        keys.api-token.from = "token";
      };

      components.otel-collector.gateway.replicas = 1;
    };
}

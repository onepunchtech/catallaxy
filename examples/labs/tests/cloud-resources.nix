{
  lab.name = "cloud-resources";
  lab.environment = "development";
  lab.network.dockerSubnet = "172.29.0.0/16";

  lab.dns.enable = false;
  lab.registry.enable = false;
  lab.proxy.enable = false;

  lab.secrets.stores.bootstrap.backend = "env";
  lab.secrets.managed.do-token = {
    store = "bootstrap";
    keys.token = { };
  };
  lab.secrets.managed.cf-token = {
    store = "bootstrap";
    keys.token = { };
  };

  lab.clusters.mgmt =
    { lab, ... }:
    {
      cluster.name = "mgmt";
      cluster.provisioner = "k3d";
      provisioner.k3d.network = lab.name;

      floes.external-secrets.enable = true;

      floes.crossplane = {
        enable = true;
        providers = [
          "digitalocean"
          "cloudflare"
        ];

        digitalocean.kubernetesClusters.demo = {
          region = "nyc3";
          version = "1.31.0-do.2";
        };
        digitalocean.droplets.jump = {
          region = "nyc3";
          size = "s-1vcpu-1gb";
          image = "ubuntu-22-04-x64";
        };
        digitalocean.loadBalancers.edge = {
          region = "nyc3";
        };

        cloudflare.zones.example-com.domain = "example.com";
        cloudflare.records.www = {
          zoneRef = "example-com";
          type = "A";
          name = "www";
          value = "203.0.113.10";
        };
      };

      # capi-operator renders with `cert-manager.enabled = false`, so it wants
      # one to already be there. Nothing said so until the requirement became
      # a name the graph resolves.
      floes.cert-manager.enable = true;

      floes.cluster-api = {
        enable = true;
        isManagementCluster = true;
        clusters.edge = {
          enable = true;
          infrastructureProvider = "docker";
        };
      };
    };
}

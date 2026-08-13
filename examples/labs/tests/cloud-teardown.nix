{ lib, ... }:
{
  lab.name = "cloud-teardown";
  lab.environment = "development";
  lab.network.dockerSubnet = "172.31.0.0/16";

  lab.dns.enable = false;
  lab.registry.enable = false;
  lab.proxy.enable = false;

  lab.clusters.mgmt =
    { lab, ... }:
    {
      cluster.name = "mgmt";
      cluster.provisioner = "k3d";
      provisioner.k3d.network = lab.name;

      cluster.provisions.workload = {
        resourceKind = "clusters.kubernetes.digitalocean.crossplane.io";
      };

      cluster.provisions.adopted = {
        resourceKind = "clusters.eks.aws.upbound.io";
        externalNameDiscoveryBin = "/nix/store/0000000000000000000000000000000-discover/bin/discover";
      };
    };

  lab.clusters.workload = {
    cluster.name = "workload";
    cluster.provisioner = "crossplane";
  };

  lab.clusters.adopted = {
    cluster.name = "adopted";
    cluster.provisioner = "crossplane";
  };

  lab.clusters.pivoted =
    { lab, ... }:
    {
      cluster.name = "pivoted";
      cluster.provisioner = "k3d";
      provisioner.k3d.network = lab.name;

      cluster.provisions.pivoted = {
        resourceKind = "clusters.kubernetes.digitalocean.crossplane.io";
      };
    };

  lab.destroy.rescueHints = lib.mkDefault { };
}

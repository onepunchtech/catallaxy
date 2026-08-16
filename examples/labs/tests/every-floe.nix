# Every floe in the repo, enabled somewhere, so the image completeness check
# has something to render for each one.
#
# The example labs are the labs someone would build. This is not: it is here
# because a floe nobody's example uses is still a floe someone downstream can
# depend on, and its images are still images they have to mirror. A floe that
# no lab renders is a floe whose declarations nothing checks.
#
# Grouped into clusters only where floes cannot share one, so this stays as
# few rendered trees as it can be.
{
  lab.name = "every-floe";
  lab.environment = "development";
  lab.network.dockerSubnet = "172.30.0.0/16";

  lab.dns.enable = false;
  lab.registry.enable = false;
  lab.proxy.enable = false;

  lab.clusters.core = {
    cluster.name = "core";
    cluster.provisioner = "k3d";
    provisioner.k3d.network = "every-floe";

    # On here so every floe's declarations are rendered rather than merely
    # written. core and idm have no cilium, net does, so the two dialects are
    # both exercised without a fourth cluster.
    cluster.security.networkPolicies.enable = true;

    floes.crossplane.enable = true;
    # A cluster-api floe that is not the management cluster renders nothing
    # at all, so enabling it without this would claim its images are complete
    # while checking an empty directory.
    floes.cluster-api = {
      enable = true;
      isManagementCluster = true;
      infrastructureProviders = [ "docker" ];
    };
    floes.openebs.enable = true;
    floes.redis-operator.enable = true;
    floes.seaweedfs.enable = true;
    floes.zot.enable = true;
  };

  # kanidm requires both of these, and it is the one floe here that has peers.
  lab.clusters.idm = {
    cluster.name = "idm";
    cluster.provisioner = "k3d";
    provisioner.k3d.network = "every-floe";
    cluster.security.networkPolicies.enable = true;

    floes.cert-manager.enable = true;
    floes.gateway.enable = true;
    floes.kanidm.enable = true;
  };

  # cilium replaces the CNI the other clusters run, so it gets its own.
  lab.clusters.net = {
    cluster.name = "net";
    cluster.provisioner = "k3d";
    provisioner.k3d.network = "every-floe";
    cluster.security.networkPolicies.enable = true;

    floes.cilium.enable = true;
  };
}

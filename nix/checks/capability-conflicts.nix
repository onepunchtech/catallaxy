{
  lib,
  pkgs,
  labRefusal,
}:

let
  base = {
    lab.name = "capability-fixture";
    lab.environment = "development";
    lab.dns.enable = false;
    lab.registry.enable = false;
    lab.proxy.enable = false;
  };

  refusalsFor =
    cluster:
    labRefusal {
      modules = [
        base
        {
          lab.clusters.app = lib.mkMerge [
            (
              { lab, ... }:
              {
                cluster.name = "app";
                cluster.provisioner = "k3d";
                provisioner.k3d.network = lab.name;
              }
            )
            cluster
          ];
        }
      ];
    };

  evaluates = cluster: refusalsFor cluster == [ ];

  cases = [
    {
      what = "two API gateways on one cluster";
      expect = "bundle 'cilium-gateway' conflicts with 'api-gateway', which 'gateway' also provides";
      good = {
        floes.gateway.enable = true;
        floes.cilium.enable = true;
        floes.cilium.gatewayAPI.enable = false;
      };
      bad = {
        floes.gateway.enable = true;
        floes.cilium.enable = true;
        floes.cilium.gatewayAPI.enable = true;
      };
    }
    {
      what = "openebs against the default StorageClass k3s ships";
      expect = "bundle 'cluster-provided/default-storage-class' conflicts with 'default-storage-class', which 'openebs' also provides";
      good = {
        floes.openebs.enable = true;
      };
      bad = {
        floes.openebs.enable = true;
        provisioner.k3d.noLocalStorage = lib.mkForce false;
      };
    }
    {
      what = "cilium LoadBalancer IPAM against k3s's ServiceLB";
      expect = "bundle 'cilium' conflicts with 'loadbalancer-addresses', which 'cluster-provided/loadbalancer-addresses' also provides";
      good = {
        floes.cilium.enable = true;
        floes.cilium.gatewayAPI.enable = false;
        floes.cilium.lbIPAM.enable = true;
      };
      bad = {
        floes.cilium.enable = true;
        floes.cilium.gatewayAPI.enable = false;
        floes.cilium.lbIPAM.enable = true;
        provisioner.k3d.noServiceLB = lib.mkForce false;
      };
    }
    {
      what = "cilium as the CNI against the one k3s ships";
      expect = "bundle 'cilium' conflicts with 'cni', which 'cluster-provided/cni' also provides";
      good = {
        floes.cilium.enable = true;
        floes.cilium.gatewayAPI.enable = false;
      };
      bad = {
        floes.cilium.enable = true;
        floes.cilium.gatewayAPI.enable = false;
        provisioner.k3d.noFlannel = lib.mkForce false;
      };
    }
    {
      what = "a disabled floe still counts as a provider";
      expect = "bundle 'cilium-gateway' conflicts with 'api-gateway', which 'gateway' also provides";
      good = {
        floes.gateway.enable = true;
        floes.cilium.enable = false;
        floes.cilium.gatewayAPI.enable = true;
      };
      bad = {
        floes.gateway.enable = true;
        floes.cilium.enable = true;
        floes.cilium.gatewayAPI.enable = true;
      };
    }
  ];

  # The point of addressing a capability rather than a floe: a consumer asks
  # whether its HTTPRoute will have a parent, and cilium answers. Every one of
  # these used to name the gateway floe, so this refused a provider that was
  # right there.
  resolutionCases = [
    {
      what = "cilium's Gateway API satisfies a floe that needs routing";
      cluster = {
        floes.cilium.enable = true;
        floes.cilium.gatewayAPI.enable = true;
        floes.cert-manager.enable = true;
        floes.external-secrets.enable = true;
        floes.zot = {
          enable = true;
          domain = "zot.test.local";
        };
      };
    }
    {
      what = "cilium's Gateway API satisfies grafana, which used to name the gateway floe";
      cluster = {
        floes.cilium.enable = true;
        floes.cilium.gatewayAPI.enable = true;
        floes.cert-manager.enable = true;
        floes.reloader.enable = true;
        floes.grafana = {
          enable = true;
          domain = "grafana.test.local";
        };
      };
    }
  ];

  # Emptied: the contradiction it recorded is fixed. Kept, rather than deleted
  # with the case, because the next floe to name an implementation where it
  # means a job goes here and retires itself the same way.
  knownRefusedCases = [ ];

  additiveCases = [
    {
      what = "two OCI registries on different hostnames";
      cluster = {
        floes.gateway.enable = true;
        floes.cert-manager.enable = true;
        floes.external-secrets.enable = true;
        floes.zot = {
          enable = true;
          domain = "zot.test.local";
        };
        floes.harbor = {
          enable = true;
          domain = "harbor.test.local";
        };
      };
    }
  ];

  describe =
    c:
    let
      bad = refusalsFor c.bad;
    in
    "the incompatible lab should be refused by an assertion quoting '${c.expect}', but "
    + (
      if bad == null then
        "it failed to evaluate for a reason that was not an assertion"
      else if bad == [ ] then
        "it evaluated cleanly"
      else
        "the assertions that fired were:\n" + lib.concatMapStringsSep "\n" (m: "      * ${m}") bad
    )
    + ": ${c.what}";

  failures =
    lib.concatMap (
      c:
      lib.optional (
        !(evaluates c.good)
      ) "the compatible lab should evaluate, but it was refused: ${c.what}"
      ++ lib.optional (
        let
          bad = refusalsFor c.bad;
        in
        bad == null || bad == [ ] || !(lib.any (m: lib.hasInfix c.expect m) bad)
      ) (describe c)
    ) cases
    ++ lib.concatMap (
      c:
      lib.optional (!(evaluates c.cluster)) "an additive capability was treated as exclusive: ${c.what}"
    ) additiveCases
    ++ lib.concatMap (
      c:
      lib.optional (
        !(evaluates c.cluster)
      ) "a capability went unresolved, so a consumer refused a provider that is right there: ${c.what}"
    ) resolutionCases
    ++ lib.concatMap (
      c:
      lib.optional (evaluates c.cluster) (
        "this now evaluates, so the contradiction it recorded is gone: ${c.what}\n"
        + "    Move it into resolutionCases, where it is an assertion that the\n"
        + "    capability layer resolves, and delete it from knownRefusedCases."
      )
    ) knownRefusedCases;
in
{
  two-floes-doing-one-job-is-refused = pkgs.runCommand "two-floes-doing-one-job-is-refused" { } (
    if failures == [ ] then
      ''
        echo "an exclusive capability with two providers fails evaluation" > $out
      ''
    else
      ''
        cat >&2 <<'EOF'
        A cluster is accepting two implementations of one exclusive
        capability, or refusing a combination that is fine.

        Two Gateway API implementations do not merge: they claim the same
        objects and the same traffic, and which one wins depends on the
        order things reconcile in, so the cluster comes up and then
        disagrees with itself. Additive capabilities are the opposite
        case: two registries on two hostnames is a supported
        configuration, and refusing it would make the arity flag
        meaningless.

        Each exclusive case is run twice, once in a combination that
        should work and once in one that should not, so an assertion that
        refuses everything fails here too.

        ${lib.concatStringsSep "\n" (map (f: "  - ${f}") failures)}
        EOF
        exit 1
      ''
  );
}

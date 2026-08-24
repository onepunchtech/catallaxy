{ lib }:

let
  mountsOf =
    proxy:
    let
      evaluated = lib.evalModules {
        modules = [
          ../../modules/lab
          {
            lab.name = "t";
            lab.dns.zone = "t.test";
            lab.registry.enable = false;
            lab.proxy = proxy;
            lab.clusters.c =
              { lab, ... }:
              {
                cluster.name = "c";
                cluster.provisioner = "k3d";
                provisioner.k3d.network = lab.name;
              };
          }
        ];
      };
    in
    map (v: v.hostPath) evaluated.config.lab.clusters.c.provisioner.k3d.extraVolumes;

  mountsCa = proxy: builtins.any (p: lib.hasSuffix "/proxy/ca.crt" p) (mountsOf proxy);
in
lib.runTests {
  # The lab CA is minted by the `cert-generate` step, which the deployment
  # plan emits only when the proxy terminates TLS. A cluster that mounts the
  # CA when the proxy does not serve TLS names a file no step in its own plan
  # creates, and `lab up` refuses to create the cluster on a missing mount --
  # forever, because re-running never produces the file either.
  testAProxyWithoutTlsMintsNoCaSoNothingMountsOne = {
    expr = mountsCa {
      enable = true;
      tls.enable = false;
    };
    expected = false;
  };

  testAProxyServingTlsMountsTheCaItMints = {
    expr = mountsCa {
      enable = true;
      tls.enable = true;
    };
    expected = true;
  };

  testNoProxyMeansNoCaMount = {
    expr = mountsCa { enable = false; };
    expected = false;
  };
}

{ myFloes }:

{ ... }:
{
  lab.name = "my-platform";
  lab.dns.zone = "example.test";

  lab.policy.exposure.defaultTier = "internal";

  lab.clusters.app =
    { config, ... }:
    {
      imports = [ myFloes.hello-world ];

      cluster.name = "app";
      cluster.kubernetes = {
        distribution = "k3s";
        controlPlanes = 1;
        workers = 0;
      };

      floes.gateway.enable = true;
      floes.cert-manager.enable = true;

      floes.hello-world = {
        enable = true;
        domain = "hello.example.test";
        replicas = 2;
      };
    };
}

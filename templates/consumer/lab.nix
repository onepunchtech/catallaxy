# Lab definition — your platform topology
{ lib, ... }:
{
  lab.name = "my-platform";
  lab.dns.zone = "example.test";

  lab.clusters.app =
    { ... }:
    {
      cluster.name = "app";
      cluster.kubernetes = {
        distribution = "k3s";
        controlPlanes = 1;
        workers = 0;
      };

      # Enable built-in components
      components.gateway.enable = true;
      components.cert-manager.enable = true;

      # Enable your custom component
      components.hello-world = {
        enable = true;
        domain = "hello.example.test";
        replicas = 2;
      };
    };
}

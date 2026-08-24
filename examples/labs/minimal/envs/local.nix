{ ... }:
{
  lab.name = "minimal.local";
  lab.environment = "development";

  lab.floes.k3d-local = {
    enable = true;
    clusters = [ "app" ];
  };
}

{ ... }:
{
  lab.name = "minimal.talos";
  lab.environment = "development";

  lab.floes.talos-local = {
    enable = true;
    clusters = [ "app" ];
  };
}

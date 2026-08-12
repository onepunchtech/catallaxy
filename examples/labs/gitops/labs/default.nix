{ lib, ... }:
{
  lab.name = lib.mkDefault "gitops";
  lab.dns.zone = lib.mkDefault "gitops.test";

  lab.clusters.core =
    { ... }:
    {
      imports = [ ../clusters/core.nix ];
    };
}

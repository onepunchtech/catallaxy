{ lib, pkgs }:

let
  yamlUtil = import ./yaml.nix { inherit lib pkgs; };
  dirBuilder = import ./dir-builder.nix { inherit lib pkgs yamlUtil; };
  prefixUtil = import ./prefix.nix { inherit lib pkgs; };

in
{
  inherit yamlUtil dirBuilder prefixUtil;

  chainsaw = import ./chainsaw.nix { inherit lib pkgs; };

  kapp = import ./kapp.nix {
    inherit
      lib
      pkgs
      dirBuilder
      yamlUtil
      prefixUtil
      ;
  };
  argocd = import ./argocd.nix {
    inherit
      lib
      pkgs
      dirBuilder
      yamlUtil
      prefixUtil
      ;
  };
  fleet = import ./fleet.nix {
    inherit
      lib
      pkgs
      dirBuilder
      yamlUtil
      prefixUtil
      ;
  };
}

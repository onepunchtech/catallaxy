{
  lib,
  pkgs,
  waitImages ? { },
}:

let
  yamlUtil = import ./yaml.nix { inherit lib pkgs; };
  dirBuilder = import ./dir-builder.nix {
    inherit
      lib
      pkgs
      yamlUtil
      waitImages
      ;
  };
  prefixUtil = import ./prefix.nix { inherit lib pkgs; };
  imageUtil = import ./images.nix { inherit lib pkgs; };

  deliveryBundle = {
    argocd = "argocd-root";
  };

in
{
  inherit
    yamlUtil
    dirBuilder
    prefixUtil
    imageUtil
    deliveryBundle
    ;

  chainsaw = import ./chainsaw.nix { inherit lib pkgs; };

  kapp = import ./kapp.nix {
    inherit
      lib
      pkgs
      dirBuilder
      yamlUtil
      prefixUtil
      imageUtil
      ;
  };
  argocd = import ./argocd.nix {
    inherit
      lib
      pkgs
      dirBuilder
      yamlUtil
      prefixUtil
      imageUtil
      ;
    deliveryBundle = deliveryBundle.argocd;
  };
  fleet = import ./fleet.nix {
    inherit
      lib
      pkgs
      dirBuilder
      yamlUtil
      prefixUtil
      imageUtil
      ;
  };
}

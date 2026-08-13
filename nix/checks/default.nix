{
  self,
  lib,
  pkgs,
  system,
  nixpkgs,
  pureLib,
  packages,
  treefmtEval,
  mkLab,
  exampleLabDefs,
  e2eLabs,
}:

{
  cli = packages.cataWrapped;
  cli-clippy = packages.cata.passthru.clippy;
  docs = packages.docs;
  formatting = treefmtEval.config.build.check self;
}
// import ./cli-lints.nix { inherit pkgs self; }
// import ./lib-tests.nix { inherit lib pkgs e2eLabs; }
// import ./step-kinds.nix { inherit lib pkgs system; }
// import ./host-dns.nix { inherit lib pkgs self; }
// import ./docs.nix {
  inherit pkgs;
  inherit (packages) optionDocs stepKindDocs;
}
// import ./external-floes.nix {
  inherit
    lib
    pkgs
    nixpkgs
    pureLib
    mkLab
    ;
}
// import ./examples.nix {
  inherit lib pkgs exampleLabDefs;
  inherit (packages) cataWrapped;
  fixtureLabs = {
    cloud-teardown = mkLab { modules = [ ../../examples/labs/tests/cloud-teardown.nix ]; };
  };
}

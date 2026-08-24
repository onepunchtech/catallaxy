{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    catallaxy.url = "github:onepunchtech/catallaxy";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      catallaxy,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        lib = nixpkgs.lib;

        myFloes = import ./floes {
          inherit lib;
          inherit (catallaxy.lib.floe) floeOptions;
        };

        lab = catallaxy.legacyPackages.${system}.mkLab {
          modules = [ (import ./lab.nix { inherit myFloes; }) ];
        };
      in
      {
        legacyPackages = {
          labs."my-platform" = lab.config.lab.out.cliConfig;
          labPackages."my-platform" = lab.config.lab.out.package;
        };

        devShells.default = catallaxy.legacyPackages.${system}.mkLabShell lab;

        checks = catallaxy.legacyPackages.${system}.mkLabChecks {
          labs."my-platform" = lab;
        };
      }
    );
}

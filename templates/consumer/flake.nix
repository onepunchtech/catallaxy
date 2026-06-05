# Consumer flake — extend catallaxy with custom components
#
# This template shows how to create a lab that uses catallaxy as a library
# and adds custom components without forking.
#
# Usage:
#   nix flake init -t github:onepunch/catallaxy#consumer
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    catallaxy.url = "github:onepunch/catallaxy";
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
        pkgs = import nixpkgs { inherit system; };
        mkLab = catallaxy.${system}.mkLab;
      in
      {
        labs."my-platform" =
          (mkLab {
            modules = [
              ./lab.nix
              ./components/hello-world.nix
            ];
          }).config.lab.out.cliConfig;
      }
    );
}

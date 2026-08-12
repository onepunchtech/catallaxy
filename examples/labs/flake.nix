{
  description = "Catallaxy example labs: a ladder from one cluster to a full platform";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    catallaxy.url = "path:../..";
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
        mkLab = modules: catallaxy.legacyPackages.${system}.mkLab { inherit modules; };

        allLabs = {
          "minimal.local" = mkLab [
            ./minimal/labs/default.nix
            ./minimal/envs/local.nix
          ];
          "homelab.local" = mkLab [
            ./homelab/labs/default.nix
            ./homelab/envs/local.nix
          ];
          "homelab.gitops-local" = mkLab [
            ./homelab/labs/default.nix
            ./homelab/envs/gitops-local.nix
          ];
          "mesh.local" = mkLab [
            ./mesh/labs/default.nix
            ./mesh/envs/local.nix
          ];
        };

        allOuts = lib.mapAttrs (_: lab: lab.config.lab.out) allLabs;
      in
      {

        legacyPackages = {
          labs = lib.mapAttrs (_: out: out.cliConfig) allOuts;
          labPackages = lib.mapAttrs (_: out: out.package) allOuts;
        };

        devShells = lib.mapAttrs (_: lab: catallaxy.legacyPackages.${system}.mkLabShell lab) allLabs;
      }
    );
}

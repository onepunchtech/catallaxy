{
  description = "Example: aspects + clusters + env overlays";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    catallaxy.url = "path:../..";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      catallaxy,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        mkLab = modules: catallaxy.mkLab.${system} { inherit modules; };

        allLabs = {
          "homelab.local" = mkLab [
            ./labs/default.nix
            ./envs/local.nix
          ];
          "homelab.staging" = mkLab [
            ./labs/default.nix
            ./envs/staging.nix
          ];
          "homelab.prod" = mkLab [
            ./labs/default.nix
            ./envs/prod.nix
          ];
        };

        allOuts = nixpkgs.lib.mapAttrs (_: lab: lab.config.lab.out) allLabs;
        localOut = allOuts."homelab.local";
      in
      {
        labs = nixpkgs.lib.mapAttrs (_: out: out.cliConfig) allOuts;

        labPackages = nixpkgs.lib.mapAttrs (_: out: out.package) allOuts;

        manifests = localOut.manifests;

        clusters = nixpkgs.lib.mapAttrs (
          _: clusterCfg: catallaxy.lib.clusterConfigToJSON clusterCfg
        ) localOut.allClusters;
      }
    );
}

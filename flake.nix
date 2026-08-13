{
  description = "catallaxy: declarative Kubernetes platform management";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    nix-kube-generators.url = "github:farcaller/nix-kube-generators";

    crane.url = "github:ipetkov/crane";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      nix-kube-generators,
      crane,
      rust-overlay,
      treefmt-nix,
    }:
    let
      lib = nixpkgs.lib;
      pureLib = import ./lib/pure.nix { inherit lib; };
    in
    {
      nixosModules.default =
        { ... }:
        {
          imports = [ ./modules ];
        };

      nixosModules.hostDns = ./nix/nixos/host-dns.nix;

      lib = pureLib;

      templates.consumer = {
        path = ./templates/consumer;
        description = "A catallaxy consumer flake with a custom floe";
      };
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };

        rustToolchain = pkgs.rust-bin.stable.latest.default;
        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        treefmtEval = treefmt-nix.lib.evalModule pkgs (
          import ./nix/treefmt.nix { inherit lib rustToolchain; }
        );

        kubelib = nix-kube-generators.lib { inherit pkgs; };
        cataCharts = import ./lib/charts.nix { inherit lib pkgs kubelib; };
        k8sSpecs = import ./lib/k8s-specs.nix { inherit lib pkgs cataCharts; };

        packages' = import ./pkgs {
          inherit
            self
            lib
            pkgs
            craneLib
            rustToolchain
            cataCharts
            k8sSpecs
            ;
        };

        labs = import ./lib/labs.nix {
          inherit
            lib
            pkgs
            pureLib
            cataCharts
            k8sSpecs
            ;
          modulesPath = ./modules;
          examplesPath = ./examples/labs;

          inherit (packages') tools cataWrapped;
        };

        exampleLabDefs = labs.discoverExampleLabs;

        e2eLabs = lib.mapAttrs (_: lab: lab.config.lab.out.selfContained) exampleLabDefs;

        labApp = program: {
          type = "app";
          inherit program;
        };
      in
      {
        legacyPackages = {
          inherit (labs) mkLab mkLabShell k8sTypegenConfig;
          inherit (packages') tools;
          inherit e2eLabs;
          labs = lib.mapAttrs (_: lab: lab.config.lab.out.cliConfig) exampleLabDefs;
          labPackages = lib.mapAttrs (_: lab: lab.config.lab.out.package) exampleLabDefs;
          charts = cataCharts;
        };

        packages = {
          default = packages'.cataWrapped;
          cata = packages'.cataWrapped;
          cata-unwrapped = packages'.cata;
          e2e = packages'.e2e;
          option-docs = packages'.optionDocs;
          docs = packages'.docs;
        };

        apps = {
          default = labApp "${packages'.cataWrapped}/bin/cata";
          cata = labApp "${packages'.cataWrapped}/bin/cata";
          e2e = labApp "${packages'.e2e}/bin/cata-e2e";
          generate-k8s-types = labApp (
            let
              configFile = pkgs.writeText "k8s-typegen-config.json" (builtins.toJSON labs.k8sTypegenConfig);
            in
            toString (
              pkgs.writeShellScript "generate-k8s-types" ''
                set -euo pipefail
                exec ${packages'.cata}/bin/cata-build generate ${configFile}
              ''
            )
          );
        }
        // lib.concatMapAttrs (
          name: lab:
          lib.optionalAttrs (lab.config.lab.ops.out.tool != null) {
            "${name}-ops" = labApp "${lab.config.lab.ops.out.tool}/bin/${name}-ops";
          }
        ) exampleLabDefs;

        devShells = lib.mapAttrs (_: lab: labs.mkLabShell lab) exampleLabDefs // {
          default = import ./nix/devshell.nix {
            inherit pkgs rustToolchain;
            packages = packages';
          };
        };

        formatter = treefmtEval.config.build.wrapper;

        checks = import ./nix/checks {
          inherit
            self
            lib
            pkgs
            system
            nixpkgs
            pureLib
            treefmtEval
            exampleLabDefs
            e2eLabs
            ;
          packages = packages';
          inherit (labs) mkLab;
        };
      }
    );
}

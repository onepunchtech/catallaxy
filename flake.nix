{
  description = "catallaxy — declarative Kubernetes platform management";

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

      lib = pureLib;

      templates.consumer = {
        path = ./templates/consumer;
        description = "A catallaxy consumer flake with a custom component";
      };
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs { inherit system overlays; };

        rustToolchain = pkgs.rust-bin.stable.latest.default;
        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        treefmtEval = treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";
          programs.nixfmt.enable = true;
          programs.rustfmt = {
            enable = true;
            package = rustToolchain;
            edition = "2024";
          };
          programs.yamlfmt.enable = true;
        };

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
        };

        exampleLabDefs = labs.discoverExampleLabs;

      in
      {
        # ── Lab evaluation (under legacyPackages to avoid flake check warnings) ──
        legacyPackages = {
          mkLab = labs.mkLab;
          labs = lib.mapAttrs (_: lab: lab.config.lab.out.cliConfig) exampleLabDefs;
          labPackages = lib.mapAttrs (_: lab: lab.config.lab.out.package) exampleLabDefs;
          charts = cataCharts;
          inherit (labs) k8sTypegenConfig;
        };

        # ── Packages ───────────────────────────────────────────────────────
        packages = {
          default = packages'.cataWrapped;
          cata = packages'.cataWrapped;
          cata-unwrapped = packages'.cata;
          option-docs = packages'.optionDocs;
          docs = packages'.docs;
        };

        # ── Apps ───────────────────────────────────────────────────────────
        apps = {
          default = {
            type = "app";
            program = "${packages'.cataWrapped}/bin/cata";
          };
          cata = {
            type = "app";
            program = "${packages'.cataWrapped}/bin/cata";
          };
          generate-k8s-types =
            let
              configFile = pkgs.writeText "k8s-typegen-config.json" (builtins.toJSON labs.k8sTypegenConfig);
            in
            {
              type = "app";
              program = toString (
                pkgs.writeShellScript "generate-k8s-types" ''
                  set -euo pipefail
                  exec ${packages'.cataWrapped}/bin/cata generate ${configFile}
                ''
              );
            };
        }
        // lib.concatMapAttrs (
          name: lab:
          let
            opsTool = lab.config.lab.ops.out.tool;
          in
          lib.optionalAttrs (opsTool != null) {
            "${name}-ops" = {
              type = "app";
              program = "${opsTool}/bin/${name}-ops";
            };
          }
        ) exampleLabDefs;

        # ── Development ────────────────────────────────────────────────────
        devShells.default = pkgs.mkShell {
          packages = packages'.tools ++ [
            packages'.cataWrapped
            rustToolchain
            pkgs.cargo-watch
            pkgs.rust-analyzer
            pkgs.mdbook
            pkgs.mdbook-mermaid
            (pkgs.writeShellScriptBin "cata-dev" ''
              exec cargo run --manifest-path "''${CATALLAXY_ROOT:-$(git rev-parse --show-toplevel)}/cli/Cargo.toml" -- "$@"
            '')
          ];
          shellHook = ''
            echo "catallaxy dev shell"
            echo "  cata-dev             # run CLI from source (cargo build + run)"
            echo "  cargo build          # build CLI"
            echo "  cargo watch -x run   # watch and rebuild"
          '';
        };

        # ── Formatting & checks ────────────────────────────────────────────
        formatter = treefmtEval.config.build.wrapper;

        checks = {
          cli = packages'.cataWrapped;
          formatting = treefmtEval.config.build.check self;
        }
        // lib.mapAttrs' (
          name: lab:
          lib.nameValuePair "${name}-lint" (
            pkgs.runCommand "${name}-lint" { nativeBuildInputs = [ packages'.cataWrapped ]; } ''
              cata lab lint --path ${lab.config.lab.out.package}
              touch $out
            ''
          )
        ) exampleLabDefs;
      }
    );
}

{
  description = "catallaxy — declarative Kubernetes platform management";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Kubernetes
    nix-kube-generators.url = "github:farcaller/nix-kube-generators";

    # Rust tooling
    crane.url = "github:ipetkov/crane";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Formatting
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

      # Cluster evaluation is pure (no derivations), so we can use any system for pkgs.
      # Only lib is actually used by the module system.
      evalPkgs = import nixpkgs { system = "x86_64-linux"; };
      catallaxyLib = import ./lib {
        inherit lib;
        pkgs = evalPkgs;
      };

    in
    {

      # Reusable module for external flakes
      nixosModules.default =
        { pkgs, lib, ... }:
        {
          imports = [ ./modules ];
        };

      # Library for external consumers
      lib = catallaxyLib;

    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs { inherit system overlays; };

        # Rust toolchain
        rustToolchain = pkgs.rust-bin.stable.latest.default;
        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        # Formatting
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

        # Packages (CLI, scripts)
        packages' = import ./pkgs {
          inherit
            self
            lib
            pkgs
            craneLib
            rustToolchain
            ;
        };

        kubelib = nix-kube-generators.lib { inherit pkgs; };
        cataCharts = import ./lib/charts.nix {
          inherit lib pkgs kubelib;
        };
        k8sSpecs = import ./lib/k8s-specs.nix {
          inherit lib pkgs cataCharts;
        };

        # Evaluate a lab: run modules through evalModule with catallaxy defaults
        mkLab' =
          { modules }:
          catallaxyLib.evalModule {
            modules = [
              ./modules
              {
                _module.args.cataCharts = cataCharts;
                _module.args.k8sSpecs = k8sSpecs;
              }
            ]
            ++ modules;
            specialArgs = { inherit lib pkgs; };
          };

        # Auto-discover example lab definitions (env overlays in examples/labs/envs/)
        # Each env overlay is composed with the base lab definition.
        # Lab names use dotted notation: homelab.local, homelab.staging, homelab.prod
        exampleLabDefs =
          let
            entries = builtins.readDir ./examples/labs/envs;
            isEnvFile = name: type: type == "regular" && lib.hasSuffix ".nix" name;
            envFiles = lib.filterAttrs isEnvFile entries;
          in
          lib.mapAttrs' (
            filename: _:
            let
              envName = lib.removeSuffix ".nix" filename;
            in
            lib.nameValuePair "homelab.${envName}" (mkLab' {
              modules = [
                ./examples/labs/labs/default.nix
                ./examples/labs/envs/${filename}
              ];
            })
          ) envFiles;

        k8sTypegenConfig = {
          outputDir = "modules/lab/cluster/lib/kubernetes/generated";
          k8sVersions = lib.mapAttrs (_: spec: "${spec}") k8sSpecs.specs;
          crds = k8sSpecs.crds;
        };

      in
      {
        # Centralized Helm chart definitions
        charts = cataCharts;

        # Lab evaluator and example labs
        mkLab = mkLab';
        labs = lib.mapAttrs (_: lab: lab.config.lab.out.cliConfig) exampleLabDefs;

        # Per-cluster JSON configs for CLI consumption (flattened across all labs)
        clusters = lib.concatMapAttrs (
          _: lab:
          lib.mapAttrs (
            _: clusterCfg: catallaxyLib.clusterConfigToJSON clusterCfg
          ) lab.config.lab.out.allClusters
        ) exampleLabDefs;

        # Per-cluster rendered manifests for CLI apply (flattened across all labs)
        manifests = lib.concatMapAttrs (_: lab: lab.config.lab.out.manifests) exampleLabDefs;

        # Per-cluster auto-deploy manifest packages (for k3d boot-time CNI etc.)
        autoDeployManifests = lib.concatMapAttrs (
          _: lab:
          lib.mapAttrs (
            clusterName: clusterCfg:
            let
              manifests = clusterCfg.provisioner.k3d.autoDeployManifests or [ ];
            in
            pkgs.linkFarm "autodeploy-${clusterName}" (
              map (m: {
                name = "${m.name}.yaml";
                path = m.content;
              }) manifests
            )
          ) lab.config.lab.out.allClusters
        ) exampleLabDefs;

        # Built lab packages for CLI lint and external consumption
        labPackages = lib.mapAttrs (_: lab: lab.config.lab.out.package) exampleLabDefs;

        packages = {
          default = packages'.cataWrapped;
          cata = packages'.cataWrapped;
          cata-unwrapped = packages'.cata;
          docs = pkgs.runCommand "catallaxy-docs" {
            nativeBuildInputs = [ pkgs.mdbook ];
          } ''
            cp -r ${./docs/book} src
            mdbook build src -d $out
          '';
        };

        apps = {
          default = {
            type = "app";
            program = "${packages'.cataWrapped}/bin/cata";
          };
          cata = {
            type = "app";
            program = "${packages'.cataWrapped}/bin/cata";
          };

          # Generate Kubernetes API types from packaged specs
          # Usage: nix run .#generate-k8s-types
          generate-k8s-types =
            let
              configFile = pkgs.writeText "k8s-typegen-config.json" (builtins.toJSON k8sTypegenConfig);
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
        # Per-lab ops tools: nix run .#<labname>-ops
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

        inherit k8sTypegenConfig;

        devShells.default = pkgs.mkShell {
          packages = packages'.tools ++ [
            packages'.cataWrapped
            rustToolchain
            pkgs.cargo-watch
            pkgs.rust-analyzer
            pkgs.mdbook
          ];
          shellHook = ''
            echo "catallaxy dev shell"
            echo "  cargo build          # build CLI"
            echo "  cargo watch -x run   # watch and rebuild"
          '';
        };

        formatter = treefmtEval.config.build.wrapper;

        checks = {
          cli = packages'.cataWrapped;
          formatting = treefmtEval.config.build.check self;
        }
        // lib.mapAttrs' (
          name: lab:
          lib.nameValuePair "${name}-lint" (
            pkgs.runCommand "${name}-lint"
              {
                nativeBuildInputs = [ packages'.cataWrapped ];
              }
              ''
                cata lab lint --path ${lab.config.lab.out.package}
                touch $out
              ''
          )
        ) exampleLabDefs;
      }
    );
}

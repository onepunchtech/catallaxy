{ lib }:

let
  inherit (lib) evalModules mapAttrs;

  k8sLib = import ../../modules/lab/cluster/lib/kubernetes/types.nix { inherit lib; };

  defaultArgs = {

    cataCharts = { };
    k8sSpecs = { };

    contracts = import ../contracts { inherit lib; };

    k8sHelpers = import ./stub-k8s-helpers.nix { inherit lib; };

    lab = {
      name = "test-lab";
      environment = "test";
      contextPrefix = "test";
      clusters = { };

      policy = {
        exposure.defaultTier = "public";
      };
      dns = {
        enable = false;
        zone = "test.local";
      };
      network = {
        name = "test-net";
        dockerSubnet = "172.31.0.0/16";
      };
      registry = {
        enable = false;
        port = 0;
        upstreams = [ ];
      };
    };
  };
in
{

  evalFloe =
    {
      floe,
      cluster ? { },
      providers ? { },
      # Capabilities each stubbed provider stands in for, as
      # `<floe> = [ "api-gateway" ]`. Needed because a consumer addressing a
      # capability rather than a floe finds its provider through what that
      # provider claims, and a stub claims nothing unless it says so. Named
      # here rather than mapped from the floe's name, which would be the
      # central registry the real thing deliberately does without.
      providerCapabilities ? { },
      args ? { },
    }:
    let
      mergedArgs = defaultArgs // args;

      providerModules = mapAttrs (upstreamName: exportsValue: {
        options.floes.${upstreamName} = {
          exports = lib.mkOption {
            type = lib.types.attrs;
            default = { };
          };
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
          capabilities = lib.mkOption {
            type = lib.types.attrs;
            default = { };
          };
        };
        config.floes.${upstreamName} = {
          exports = exportsValue;
          capabilities.provides = lib.genAttrs (providerCapabilities.${upstreamName} or [ ]) (_: { });
        };
      }) providers;

      result = evalModules {
        modules = [
          floe

          ../../modules/lab/cluster/prerequisites.nix

          # Capability resolution is a module, not something a constructor
          # computes and hands in, so a harness that wants it has to import it
          # the same way a cluster does.
          ../../modules/lab/cluster/capabilities.nix

          {
            options.bundles = lib.mkOption {
              type = lib.types.attrsOf k8sLib.bundleType;
              default = { };
            };

          }

          # The cluster lifts each floe's bundles into `bundles`; a harness
          # that wants to look at what a floe declared has to do the same.
          (
            { config, ... }:
            {
              bundles = lib.mkMerge (lib.mapAttrsToList (_: floe: floe.bundles or { }) (config.floes or { }));
            }
          )

          {
            options.assertions = lib.mkOption {
              type = lib.types.listOf (
                lib.types.submodule {
                  options = {
                    assertion = lib.mkOption { type = lib.types.bool; };
                    message = lib.mkOption { type = lib.types.str; };
                  };
                }
              );
              default = [ ];
            };
            options.warnings = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };

            options.steps = lib.mkOption {
              type = lib.types.attrsOf (
                (import ../../modules/lab/planner/types.nix { inherit lib; }).clusterStepType
              );
              default = { };
            };
            options.lifecycle = lib.mkOption {
              type = lib.types.submodule {
                options.preProvision = lib.mkOption {
                  type = lib.types.listOf lib.types.attrs;
                  default = [ ];
                };
              };
              default = { };
            };
            # Two levels, matching the real option. A single `attrsOf attrs`
            # accepts the nested shape one level shallower, which lets a test
            # assert on the wrong depth and pass.
            options.ops = lib.mkOption {
              type = lib.types.attrsOf (lib.types.attrsOf lib.types.attrs);
              default = { };
            };
            options.secrets.projections = lib.mkOption {
              type = lib.types.attrsOf lib.types.attrs;
              default = { };
            };
            options.resources = lib.mkOption {
              type = lib.types.attrsOf lib.types.attrs;
              default = { };
            };
          }

        ]
        ++ (builtins.attrValues providerModules)
        ++ [ cluster ];
        specialArgs = {
          inherit lib;
        }
        // mergedArgs;
      };

      cfg = result.config;

      floeNames = builtins.attrNames (cfg.floes or { });
      soleFloe = if (builtins.length floeNames) == 1 then builtins.head floeNames else null;
      soleFloeCfg = if soleFloe != null then cfg.floes.${soleFloe} else { };
    in
    {
      manifests = cfg.bundles or { };
      exports = if soleFloe != null then soleFloeCfg.exports or { } else { };
      config = cfg;
    };
}

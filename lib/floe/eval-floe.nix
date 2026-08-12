{ lib }:

let
  inherit (lib) evalModules mapAttrs;

  defaultArgs = {

    cataCharts = { };
    k8sSpecs = { };

    contracts = import ../contracts { inherit lib; };

    k8sHelpers = {
      mkGatewayParent = args: args;
      mkHttpRoute = args: {
        apiVersion = "gateway.networking.k8s.io/v1";
        kind = "HTTPRoute";
        inherit (args) name namespace;
        spec = args;
      };
      mkTlsRoute = args: {
        apiVersion = "gateway.networking.k8s.io/v1alpha2";
        kind = "TLSRoute";
        inherit (args) name namespace;
        spec = args;
      };
      mkCertificate = args: {
        apiVersion = "cert-manager.io/v1";
        kind = "Certificate";
        inherit (args) name namespace;
        spec = args;
      };

      wait = import ../util/wait.nix { inherit lib; };
    };

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
      args ? { },
    }:
    let
      mergedArgs = defaultArgs // args;

      providerModules = mapAttrs (upstreamName: exportsValue: {
        options.floes.${upstreamName}.exports = lib.mkOption {
          type = lib.types.attrs;
          default = { };
        };
        config.floes.${upstreamName}.exports = exportsValue;
      }) providers;

      result = evalModules {
        modules = [
          floe

          {
            options.bundles = lib.mkOption {
              type = lib.types.attrsOf (lib.types.submodule { freeformType = lib.types.attrs; });
              default = { };
            };
          }

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
            options.ops = lib.mkOption {
              type = lib.types.attrsOf lib.types.attrs;
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
            options.compose = lib.mkOption {
              type = lib.types.attrsOf lib.types.attrs;
              default = { };
            };
            options.databases.postgres = lib.mkOption {
              type = lib.types.attrsOf lib.types.attrs;
              default = { };
            };
            options.databases.redis = lib.mkOption {
              type = lib.types.attrsOf lib.types.attrs;
              default = { };
            };
            options.storage.s3Buckets = lib.mkOption {
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
      exports = if soleFloe != null then soleFloeCfg.exports else { };
      config = cfg;
    };
}

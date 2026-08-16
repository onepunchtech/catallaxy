# Everything the CLI reads about a lab, in one attrset. It is the widest
# output by a distance, which is why it has a file: it is a serialisation
# format, and reading it should not mean scrolling past the manifest
# renderers to find it.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkOption types;

  catallaxyLib = import ../../../lib/eval/cluster.nix { inherit lib pkgs; };
in
{
  options.lab.out = {
    cliConfig = mkOption {
      type = types.attrs;
      readOnly = true;
      internal = true;
      description = ''
        JSON-serializable lab configuration for the CLI.
        Contains the fields that `cata lab` commands need:
        management, clusterNames, services, network, registryPort, dnsInfo.
      '';
    };

  };

  config.lab.out = {
    cliConfig = {
      clusterNames = config.lab.out.clusterNames;
      services =
        lib.optionalAttrs config.lab.dns.enable {
          dns = config.lab.dns.out.service;
        }
        // lib.optionalAttrs config.lab.registry.enable {
          registry = config.lab.registry.service;
        }
        // lib.optionalAttrs config.lab.proxy.enable {
          proxy = config.lab.proxy.out.service;
        }
        // lib.optionalAttrs config.lab.bgpRouter.enable {
          bgpRouter = config.lab.bgpRouter.out.service;
        };
      labName = config.lab.name;
      environment = config.lab.environment;
      verify = config.lab.out.verifyConfig;
      selfContained = config.lab.out.selfContained;
      labNamespaces = config.lab.out.labNamespaces;
      network = {
        name = config.lab.name;
        dockerSubnet = config.lab.network.dockerSubnet;
      };
      registryPort = if config.lab.registry.enable then config.lab.registry.port else null;
      registryUpstreams =
        if config.lab.registry.enable then map (u: u.host) config.lab.registry.upstreams else [ ];

      labOwnedRegistries = lib.unique (map (img: img.destinationRegistry) config.lab.out.publishImages);
      dnsInfo = if config.lab.dns.enable then config.lab.dns.out.dnsInfo else null;
      cd = {
        strategy = config.lab.cd.strategy;

        bootstrap = config.lab.cd.bootstrap;
        git = config.lab.cd.git;
      };
      opsToolPath =
        if config.lab.ops.out.tool != null then
          "${config.lab.ops.out.tool}/bin/${config.lab.name}-ops"
        else
          null;

      clusters = lib.mapAttrs (
        _: clusterCfg:
        (catallaxyLib.clusterConfigToJSON clusterCfg)
        // {
          labName = config.lab.name;
        }
      ) config.lab.out.allClusters;

      secrets = {
        inherit (config.lab.secrets) envFile;

        stores = lib.mapAttrs (name: store: {
          inherit (store) backend;
        }) config.lab.secrets.stores;

        managed = lib.mapAttrs (name: sec: {
          inherit (sec) store kind;
          keys = lib.mapAttrs (kname: key: {
            inherit (key) generator length;
          }) sec.keys;
        }) config.lab.secrets.managed;

        hostProjections = config.lab.secrets.out.hostProjections;
      };

      deploymentPlan = config.lab.out.deploymentPlan;
      teardownPlan = config.lab.out.teardownPlan;

      destroy = {
        rescueHints = config.lab.destroy.rescueHints;
      };

      runtimeContexts = config.lab.out.runtimeContexts;
    };

  };
}

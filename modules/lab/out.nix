{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkOption
    types
    ;

  renderers = import ../../lib/renderers { inherit lib pkgs; };
  catallaxyLib = import ../../lib/eval.nix { inherit lib pkgs; };

in
{
  options = {
    lab.out = {
      cliConfig = mkOption {
        type = types.attrs;
        readOnly = true;
        description = ''
          JSON-serializable lab configuration for the CLI.
          Contains the fields that `cata lab` commands need:
          management, clusterNames, services, network, registryPort, dnsInfo.
        '';
      };

      allClusters = mkOption {
        type = types.attrsOf types.attrs;
        readOnly = true;
        description = ''
          Computed attrset of all clusters in the lab.
          Keys are cluster names, values are evaluated cluster configs.
          Use this for cross-cluster references.
        '';
      };

      clusterNames = mkOption {
        type = types.listOf types.str;
        readOnly = true;
        description = "List of all cluster names in the lab";
      };

      labNamespaces = mkOption {
        type = types.attrsOf (types.listOf types.str);
        readOnly = true;
        description = ''
          Per-cluster list of lab-created namespaces (before prefix application).
          Used by checks to verify prefix completeness.
        '';
      };

      manifests = mkOption {
        type = types.attrsOf types.package;
        readOnly = true;
        description = ''
          Per-cluster rendered manifest packages.
          Each package contains the strategy-specific directory layout
          (kapp, argocd, or fleet) with human-readable YAML manifests.
        '';
      };

      bootstrapManifests = mkOption {
        type = types.attrsOf types.package;
        readOnly = true;
        description = ''
          Per-cluster kapp-format manifests for direct-apply bootstrap.
          When strategy is kapp, this equals manifests. Otherwise renders
          with kapp for use by `lab up` (which always direct-applies).
        '';
      };

      package = mkOption {
        type = types.package;
        readOnly = true;
        description = ''
          Single package containing all lab outputs.
          Includes metadata.json (pretty-printed) and manifests/ directory
          with symlinks to each cluster's rendered manifests.
        '';
      };
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
        // lib.optionalAttrs config.lab.ingress.enable {
          ingress = config.lab.ingress.out.service;
        }
        // lib.optionalAttrs config.lab.bgpRouter.enable {
          bgpRouter = config.lab.bgpRouter.out.service;
        };
      labName = config.lab.name;
      environment = config.lab.environment;
      network = {
        name = config.lab.name;
        dockerSubnet = config.lab.network.dockerSubnet;
      };
      registryPort = if config.lab.registry.enable then config.lab.registry.port else null;
      dnsInfo = if config.lab.dns.enable then config.lab.dns.out.dnsInfo else null;
      cd = {
        strategy = config.lab.cd.strategy;
        git = config.lab.cd.git;
      };
      opsToolPath =
        if config.lab.ops.out.tool != null then
          "${config.lab.ops.out.tool}/bin/${config.lab.name}-ops"
        else
          null;

      # Per-cluster configs for CLI consumption (provisioner details, components, etc.)
      clusters = lib.mapAttrs (
        _: clusterCfg:
        (catallaxyLib.clusterConfigToJSON clusterCfg) // {
          labName = config.lab.name;
        }
      ) config.lab.out.allClusters;

      # Lab-level secrets for CLI consumption
      secrets = {
        stores = lib.mapAttrs (name: store: {
          inherit (store) backend;
        }) config.lab.secrets.stores;

        managed = lib.mapAttrs (name: sec: {
          inherit (sec) store;
          keys = lib.mapAttrs (kname: key: {
            inherit (key) generator length;
          }) sec.keys;
        }) config.lab.secrets.managed;
      };

      # Deployment plan for the CLI executor
      deploymentPlan = config.lab.out.deploymentPlan;
      teardownPlan = config.lab.out.teardownPlan;
    };

    allClusters = config.lab.clusters;

    clusterNames = lib.attrNames config.lab.out.allClusters;

    labNamespaces = lib.mapAttrs (
      name: clusterCfg:
      lib.unique (
        lib.concatMap (
          phaseName:
          let
            phase = clusterCfg.phases.${phaseName};
            bundleValues = lib.attrValues phase.bundles;
          in
          lib.concatMap (b: b.createNamespaces) bundleValues
        ) (lib.attrNames clusterCfg.phases)
      )
    ) config.lab.out.allClusters;

    manifests =
      let
        strategy = config.lab.cd.strategy;
        renderer = renderers.${strategy};
        cdConfig = config.lab.cd.${strategy};
        prefix = config.lab.prefix;
      in
      lib.mapAttrs (
        name: clusterCfg:
        renderer {
          clusterName = name;
          inherit prefix;
          labNamespaces = config.lab.out.labNamespaces.${name};
          phases = clusterCfg.cluster.out.phases;
          phaseOrder = clusterCfg.cluster.out.phaseOrder;
          deployConfig = cdConfig // {
            targetPath = config.lab.cd.clusterPaths.${name} or "manifests/${name}";
          };
        }
      ) config.lab.out.allClusters;

    bootstrapManifests =
      let
        strategy = config.lab.cd.strategy;
        prefix = config.lab.prefix;
      in
      if strategy == "kapp" then
        config.lab.out.manifests
      else
        lib.mapAttrs (
          name: clusterCfg:
          renderers.kapp {
            clusterName = name;
            inherit prefix;
            labNamespaces = config.lab.out.labNamespaces.${name};
            phases = clusterCfg.cluster.out.phases;
            phaseOrder = clusterCfg.cluster.out.phaseOrder;
            deployConfig = config.lab.cd.kapp;
          }
        ) config.lab.out.allClusters;

    package =
      let
        metadata = {
          name = config.lab.name;
          prefix = config.lab.prefix;
          clusterNames = config.lab.out.clusterNames;
          cd = {
            strategy = config.lab.cd.strategy;
            config = config.lab.cd.${config.lab.cd.strategy};
          };
          labNamespaces = config.lab.out.labNamespaces;
          clusters = lib.mapAttrs (
            name: clusterCfg:
            let
              topology = clusterCfg.cluster.out.topology // {
                components = lib.filterAttrs (_: c: c.enabled) clusterCfg.cluster.out.topology.components;
              };
              sbom = clusterCfg.cluster.out.sbom // {
                components = lib.filterAttrs (_: c: c.enabled) clusterCfg.cluster.out.sbom.components;
              };
            in
            {
              inherit topology sbom;
            }
          ) config.lab.out.allClusters;
        };
        metadataJson = builtins.toJSON metadata;
        manifestLinks = lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            name: pkg: "ln -s ${pkg}/${name} $out/manifests/${name}"
          ) config.lab.out.manifests
        );
        # Collect all teardown hook packages so they get built with the lab package
        teardownHookLinks = lib.concatStringsSep "\n" (
          lib.concatLists (
            lib.mapAttrsToList (
              clusterName: clusterCfg:
              map (step:
                "ln -s ${step.package}/bin/${step.name} $out/hooks/${clusterName}-${step.name}"
              ) (clusterCfg.lifecycle.teardown or [ ])
            ) config.lab.out.allClusters
          )
        );
        hasTeardownHooks = teardownHookLinks != "";
        strategy = config.lab.cd.strategy;
        bootstrapLinks =
          if strategy == "kapp" then
            "ln -s $out/manifests $out/bootstrap"
          else
            lib.concatStringsSep "\n" (
              lib.mapAttrsToList (
                name: pkg: "ln -s ${pkg}/${name} $out/bootstrap/${name}"
              ) config.lab.out.bootstrapManifests
            );
      in
      pkgs.runCommand "lab-${config.lab.name}"
        {
          nativeBuildInputs = [ pkgs.jq ];
          passAsFile = [ "metadataText" ];
          metadataText = metadataJson;
        }
        ''
          mkdir -p $out/manifests $out/bin
          ${lib.optionalString (strategy != "kapp") "mkdir -p $out/bootstrap"}
          ${lib.optionalString hasTeardownHooks "mkdir -p $out/hooks"}
          jq . "$metadataTextPath" > $out/metadata.json
          ${manifestLinks}
          ${bootstrapLinks}
          ${teardownHookLinks}
          ${
            if config.lab.ops.out.tool != null then
              "ln -s ${config.lab.ops.out.tool}/bin/${config.lab.name}-ops $out/bin/${config.lab.name}-ops"
            else
              ""
          }
        '';
  };
}

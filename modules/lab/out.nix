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

  renderers = import ../../lib/render { inherit lib pkgs; };
  catallaxyLib = import ../../lib/eval/cluster.nix { inherit lib pkgs; };

  wavesForView =
    view: waves:
    let
      keep = b: view.packages ? ${b.name} || lib.hasPrefix "projection/" b.name;
    in
    lib.filter (w: w != [ ]) (map (w: lib.filter keep w) waves);

in
{
  options = {
    lab.out = {
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

      allClusters = mkOption {
        type = types.attrsOf types.attrs;
        readOnly = true;
        internal = true;
        description = ''
          Computed attrset of all clusters in the lab.
          Keys are cluster names, values are evaluated cluster configs.
          Use this for cross-cluster references.
        '';
      };

      clusterNames = mkOption {
        type = types.listOf types.str;
        readOnly = true;
        internal = true;
        description = "List of all cluster names in the lab";
      };

      shell = mkOption {
        type = types.attrs;
        readOnly = true;
        internal = true;
        description = "Dev-shell inputs for this lab (packages + variables).";
      };

      runtimeContexts = mkOption {
        type = types.attrsOf types.str;
        readOnly = true;
        internal = true;
        description = ''
          Per-cluster kubectl context an operator should use RIGHT NOW.
          Distinct from cluster.ref.kubeContext, which is provisioner-
          baked (e.g. k3d-<lab>-<cluster> for k3d, or
          <contextPrefix>-<cluster> for Crossplane targets).
          Post-pivot for a Crossplane-provisioned cluster (self-
          provisioning or otherwise), the runtime context is the
          bare cluster-name alias that sync-kubeconfig installs; the
          Nix-baked provisioner context is either stale (destroyed k3d
          bootstrap) or never existed (DOKS never got the prefixed
          name). This attrset flattens the resolution: consumers look
          up by cluster name, get the right context regardless of
          whether the cluster is pivoted, local, or external.

          Populated by the planner from provisionerGraph. Callers
          outside the planner (CLI, ops commands, lifecycle hooks)
          should prefer this over cluster.ref.kubeContext.
        '';
      };

      labNamespaces = mkOption {
        type = types.attrsOf (types.listOf types.str);
        readOnly = true;
        internal = true;
        description = ''
          Per-cluster list of lab-created namespaces (before prefix application).
          Used by checks to verify prefix completeness.
        '';
      };

      verifyTests = mkOption {
        type = types.attrsOf types.package;
        readOnly = true;
        internal = true;
        description = ''
          Per-cluster Chainsaw Test packages, linked into the lab package at
          `verify/<cluster>/`. `cata lab verify` runs them against that
          cluster's runtime context.
        '';
      };

      manifests = mkOption {
        type = types.attrsOf types.package;
        readOnly = true;
        internal = true;
        description = ''
          Per-cluster rendered manifest packages.
          Each package contains the strategy-specific directory layout
          (kapp, argocd, or fleet) with human-readable YAML manifests.
        '';
      };

      bootstrapManifests = mkOption {
        type = types.attrsOf types.package;
        readOnly = true;
        internal = true;
        description = ''
          Per-cluster kapp-format manifests for direct-apply bootstrap.
          When strategy is kapp, this equals manifests. Otherwise renders
          with kapp for use by `lab up` (which always direct-applies).
        '';
      };

      stage1Manifests = mkOption {
        type = types.attrsOf types.package;
        readOnly = true;
        internal = true;
        description = ''
          Per-cluster restricted manifest packages for the bootstrap
          stage of self-provisioning clusters. Populated only when
          `cluster.provisioning.rootBundles` is non-empty. Contains the
          DAG closure of those roots; typically just what Crossplane
          needs to bring the cloud version of the cluster up (CRDs +
          namespaces + operators + secrets + workloads).
        '';
      };

      package = mkOption {
        type = types.package;
        readOnly = true;
        internal = true;
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
        envFile = if config.lab.secrets.envFile == null then null else toString config.lab.secrets.envFile;

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

    allClusters = config.lab.clusters;

    shell = {
      packages = lib.unique (
        lib.concatMap (c: c.shell.packages or [ ]) (lib.attrValues config.lab.out.allClusters)
      );
      variables = {
        CATALLAXY_LAB = config.lab.name;
        CATALLAXY_FLAKE = ".#${config.lab.name}";
      };
    };

    clusterNames = lib.attrNames config.lab.out.allClusters;

    labNamespaces = lib.mapAttrs (
      name: clusterCfg:
      lib.unique (lib.concatMap (b: b.createNamespaces) (lib.attrValues clusterCfg.bundles))
    ) config.lab.out.allClusters;

    verifyTests = lib.mapAttrs (
      name: clusterCfg:
      renderers.chainsaw.mkVerifyTest {
        labName = config.lab.name;
        clusterName = name;
        checks = clusterCfg.verify.out.checks;
      }
    ) config.lab.out.allClusters;

    manifests =
      let
        strategy = config.lab.cd.strategy;
        renderer = renderers.${strategy};
        cdConfig = config.lab.cd.${strategy};
        prefix = config.lab.prefix;

        useFiltering = config.lab.cd.useOwnerFiltering;
        viewFor =
          clusterCfg:
          if !useFiltering then
            clusterCfg.cluster.out.bundleView
          else if strategy == "kapp" then
            clusterCfg.cluster.out.imperativeBundleView
          else
            clusterCfg.cluster.out.argocdBundleView;
      in
      lib.mapAttrs (
        name: clusterCfg:
        let
          view = viewFor clusterCfg;
          filteredWaves = wavesForView view clusterCfg.cluster.out.manifestWaves;
        in
        renderer (
          {
            clusterName = name;
            inherit prefix;
            inherit (view) packages;
            labNamespaces = config.lab.out.labNamespaces.${name};
            deployConfig = cdConfig // {
              targetPath = config.lab.cd.clusterPaths.${name} or "manifests/${name}";
            };
          }

          // lib.optionalAttrs (strategy == "kapp" || strategy == "argocd" || strategy == "fleet") {
            waves = filteredWaves;
          }

          // lib.optionalAttrs (strategy == "argocd") {
            bootstrapMethod = config.lab.cd.bootstrap;
          }
        )
      ) config.lab.out.allClusters;

    bootstrapManifests =
      let
        strategy = config.lab.cd.strategy;
        prefix = config.lab.prefix;
        useFiltering = config.lab.cd.useOwnerFiltering;

        viewFor =
          clusterCfg:
          if useFiltering then
            clusterCfg.cluster.out.imperativeBundleView
          else
            clusterCfg.cluster.out.bundleView;
      in
      if strategy == "kapp" then
        config.lab.out.manifests
      else
        lib.mapAttrs (
          name: clusterCfg:
          let
            view = viewFor clusterCfg;
          in
          renderers.kapp {
            clusterName = name;
            inherit prefix;
            inherit (view) packages;
            labNamespaces = config.lab.out.labNamespaces.${name};
            deployConfig = config.lab.cd.kapp;
            waves = wavesForView view clusterCfg.cluster.out.manifestWaves;
          }
        ) config.lab.out.allClusters;

    stage1Manifests =
      let
        prefix = config.lab.prefix;
        stage1KeysOf =
          clusterCfg:
          lib.genAttrs (map (b: b.name) (
            lib.filter (b: builtins.elem "stage1" (b.provides or [ ])) (
              lib.concatLists clusterCfg.cluster.out.manifestWaves
            )
          )) (_: true);
      in
      lib.filterAttrs (_: v: v != null) (
        lib.mapAttrs (
          name: clusterCfg:
          let
            stage1Keys = stage1KeysOf clusterCfg;
            full = clusterCfg.cluster.out.stage1BundleView;
            view = {
              bundles = lib.filterAttrs (n: _: stage1Keys ? ${n}) full.bundles;
              packages = lib.filterAttrs (n: _: stage1Keys ? ${n}) full.packages;
            };
          in
          if view.packages == { } then
            null
          else
            renderers.kapp {
              clusterName = name;
              inherit prefix;
              inherit (view) packages;
              labNamespaces = config.lab.out.labNamespaces.${name};
              deployConfig = config.lab.cd.kapp;
              waves = wavesForView view clusterCfg.cluster.out.manifestWaves;
            }
        ) config.lab.out.allClusters
      );

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

          lint.checks = lib.mapAttrs (name: check: {
            inherit (check)
              description
              severity
              scope
              format
              ;
          }) config.lab.lint.checks;

          images = {
            inherit (config.lab.images) requireDigest allowedRegistries;
            pins = lib.mapAttrs (_: pin: {
              inherit (pin)
                image
                tag
                digest
                ref
                ;
            }) config.lab.images.pins;
          };

          secrets = {
            envFile = if config.lab.secrets.envFile == null then null else toString config.lab.secrets.envFile;
            stores = lib.mapAttrs (_: store: {
              inherit (store) backend;
            }) config.lab.secrets.stores;
            managed = lib.mapAttrs (_: sec: {
              inherit (sec) store;
              keys = lib.mapAttrs (_: key: {
                inherit (key) generator length;
              }) sec.keys;
            }) config.lab.secrets.managed;
          };

          assertions = config.lab.assertions;
          warnings = config.lab.warnings;

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

              projections = lib.mapAttrs (_: proj: {
                inherit (proj) source namespace;
                keys = lib.mapAttrs (_: key: {
                  inherit (key) from transform;
                  jsonKey = key.jsonKey or null;
                }) proj.keys;
              }) clusterCfg.secrets.projections;

              runtimeMaterialised = lib.pipe clusterCfg.floes [
                (lib.mapAttrsToList (_: floe: lib.attrValues (floe.exports or { })))
                lib.concatLists
                (lib.filter (v: builtins.isAttrs v && v ? name && v ? readyToken))
                (map (v: v.name))
                lib.unique
              ];

              copiedInSecrets = lib.pipe (lib.attrValues (config.lab.steps or { })) [
                (lib.filter (
                  step: (step.kind or "") == "cross-cluster-secret-copy" && (step.params.targetCluster or "") == name
                ))
                (map (step: step.params.targetSecret))
                lib.unique
              ];

              assertions = clusterCfg.assertions;
              warnings = clusterCfg.warnings;
            }
          ) config.lab.out.allClusters;
        };
        metadataJson = builtins.toJSON metadata;
        verifyCopies = lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            name: pkg: "cp -rL ${pkg}/${name} $out/verify/${name}"
          ) config.lab.out.verifyTests
        );

        manifestLinks = lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            name: pkg: "ln -s ${pkg}/${name} $out/manifests/${name}"
          ) config.lab.out.manifests
        );

        stage1Links = lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            name: pkg: "ln -s ${pkg}/${name} $out/stage1/${name}"
          ) config.lab.out.stage1Manifests
        );
        hasStage1 = stage1Links != "";

        hookBinPath =
          step:
          let
            mainProgram = step.package.meta.mainProgram or null;
          in
          if mainProgram != null then
            "${step.package}/bin/${mainProgram}"
          else
            "${step.package}/bin/${step.name}";
        teardownHookLinks = lib.concatStringsSep "\n" (
          lib.concatLists (
            lib.mapAttrsToList (
              clusterName: clusterCfg:
              map (step: "ln -s ${hookBinPath step} $out/hooks/${clusterName}-${step.name}") (
                clusterCfg.lifecycle.preProvision or [ ]
              )
            ) config.lab.out.allClusters
          )
        );

        stepBinLinks = lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: step: "ln -s ${step.params.bin} $out/hooks/step-${name}") (
            lib.filterAttrs (_: s: s.params ? bin) config.lab.steps
          )
        );

        discovererLinks = lib.concatStringsSep "\n" (
          lib.concatLists (
            lib.mapAttrsToList (
              clusterName: clusterCfg:
              lib.mapAttrsToList (
                target: provisioned:
                "ln -s ${provisioned.externalNameDiscoveryBin} $out/hooks/${clusterName}-discoverer-${target}"
              ) (lib.filterAttrs (_: p: p.externalNameDiscoveryBin != null) clusterCfg.cluster.provisions)
            ) config.lab.out.allClusters
          )
        );
        hasTeardownHooks = teardownHookLinks != "" || stepBinLinks != "" || discovererLinks != "";

        autoDeployLinks = lib.concatStringsSep "\n" (
          lib.concatLists (
            lib.mapAttrsToList (
              clusterName: clusterCfg:
              let
                manifests = clusterCfg.provisioner.k3d.autoDeployManifests or [ ];
              in
              lib.optionals (manifests != [ ]) (
                [ "mkdir -p $out/autodeploy/${clusterName}" ]
                ++ map (m: "ln -s ${m.content} $out/autodeploy/${clusterName}/${m.name}.yaml") manifests
              )
            ) config.lab.out.allClusters
          )
        );

        lintCheckScripts = lib.mapAttrs (
          name: check:
          pkgs.writeShellApplication {
            inherit name;
            runtimeInputs = [
              pkgs.yq-go
              pkgs.jq
              pkgs.coreutils
            ];
            text = check.command;
          }
        ) config.lab.lint.checks;
        lintCheckLinks = lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: script: "ln -s ${script}/bin/${name} $out/lint/${name}") lintCheckScripts
        );
        hasLintChecks = config.lab.lint.checks != { };

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
          nativeBuildInputs = [
            pkgs.jq
            pkgs.yq-go
          ];
          passAsFile = [ "metadataText" ];
          metadataText = metadataJson;
        }
        ''
          mkdir -p $out/manifests $out/bin $out/verify
          ${lib.optionalString (strategy != "kapp") "mkdir -p $out/bootstrap"}
          ${lib.optionalString hasStage1 "mkdir -p $out/stage1"}
          ${lib.optionalString hasTeardownHooks "mkdir -p $out/hooks"}
          ${lib.optionalString hasLintChecks "mkdir -p $out/lint"}
          jq . "$metadataTextPath" > $out/metadata.json
          ${manifestLinks}
          ${verifyCopies}
          ${bootstrapLinks}
          ${stage1Links}
          ${teardownHookLinks}
          ${stepBinLinks}
          ${discovererLinks}
          ${lintCheckLinks}
          ${autoDeployLinks}

          touch $out/images-raw.txt
          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (name: pkg: ''
              for f in $(find ${pkg}/${name} -name '*.yaml' -type f); do
                yq -N 'select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" or .kind == "Job" or .kind == "CronJob" or .kind == "Pod") | .spec.template.spec.containers[].image' "$f" 2>/dev/null >> $out/images-raw.txt || true
                yq -N 'select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" or .kind == "Job" or .kind == "CronJob" or .kind == "Pod") | .spec.template.spec.initContainers[].image' "$f" 2>/dev/null >> $out/images-raw.txt || true
                yq -N 'select(.kind == "CronJob") | .spec.jobTemplate.spec.template.spec.containers[].image' "$f" 2>/dev/null >> $out/images-raw.txt || true
              done
            '') config.lab.out.manifests
          )}
          sort -u $out/images-raw.txt | grep -v '^$' | grep -v '^null$' > $out/images.txt || touch $out/images.txt
          rm -f $out/images-raw.txt
          ${
            if config.lab.ops.out.tool != null then
              "ln -s ${config.lab.ops.out.tool}/bin/${config.lab.name}-ops $out/bin/${config.lab.name}-ops"
            else
              ""
          }
        '';
  };
}

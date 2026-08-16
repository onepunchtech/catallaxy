# The single derivation a lab builds to. `nix build .#labPackages."<lab>"`
# lands here.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkOption types;

  imageUtil = import ../../../lib/render/images.nix { inherit lib pkgs; };
in
{
  options.lab.out = {
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

  config.lab.out = {
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

          images = {
            inherit (config.lab.images) requireDigest allowedRegistries;
          };

          secrets = {
            inherit (config.lab.secrets) envFile;
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

              lint.checks = lib.mapAttrs (_: check: {
                inherit (check)
                  description
                  severity
                  scope
                  format
                  ;
              }) clusterCfg.lint.out.checks;

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

              assertions = clusterCfg.assertions;
              warnings = clusterCfg.warnings;

              # What the floes said they serve, for the lint to compare
              # against the Services this cluster actually renders. `serves`
              # is the half a human writes a number into, so it is the half
              # worth checking against reality.
              networkPolicies = clusterCfg.cluster.out.networkDeclarations;
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

        # A floe's check only applies to a cluster the floe is enabled on, so
        # the scripts are per cluster rather than one flat lab-wide set.
        lintCheckScripts = lib.mapAttrs (
          clusterName: clusterCfg:
          lib.mapAttrs (
            name: check:
            pkgs.writeShellApplication {
              name = "${clusterName}-${name}";
              runtimeInputs = [
                pkgs.yq-go
                pkgs.jq
                pkgs.coreutils
              ];
              text = check.command;
            }
          ) clusterCfg.lint.out.checks
        ) config.lab.out.allClusters;

        lintCheckLinks = lib.concatStringsSep "\n" (
          lib.concatLists (
            lib.mapAttrsToList (
              clusterName: scripts:
              lib.optionals (scripts != { }) (
                [ "mkdir -p $out/lint/${clusterName}" ]
                ++ lib.mapAttrsToList (
                  name: script: "ln -s ${script}/bin/${clusterName}-${name} $out/lint/${clusterName}/${name}"
                ) scripts
              )
            ) lintCheckScripts
          )
        );

        hasLintChecks = lintCheckLinks != "";

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
              for f in $(find -L ${pkg}/${name} -name '*.yaml' -type f); do
                yq -N '${imageUtil.scrapeExpr}' "$f" 2>/dev/null >> $out/images-raw.txt || true
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

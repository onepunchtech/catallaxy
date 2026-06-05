{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkOption types;
  render = import ../../../lib/render/manifest.nix { inherit lib pkgs; };

in

{
  options.cluster.out = {
    topology = mkOption {
      type = types.attrs;
      description = "Computed topology/network map";
    };

    sbom = mkOption {
      type = types.attrs;
      description = "Software bill of materials";
    };

    phases = mkOption {
      type = types.raw;
      default = { };
      description = ''
        Computed phases with rendered manifest packages.
        Each entry has: order, dependsOn, keepResources, pruneStrategy,
        waitForReady, timeout, package (derivation).
      '';
    };

    phaseOrder = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Phase names sorted by deployment order";
    };
  };

  config.cluster.out = {
    topology = {
      name = config.cluster.name;
      provider = config.cluster.provider;
      nodes = {
        inherit (config.cluster.kubernetes) controlPlanes workers;
      };
      network = config.cluster.network;
      components = lib.mapAttrs (n: c: { enabled = c.enable or false; }) config.components;
    };

    sbom = {
      components = lib.mapAttrs (n: c: {
        version = c.version or "unknown";
        enabled = c.enable or false;
      }) config.components;
    };

    phases =
      let
        # Collect ALL namespaces from ALL phases upfront.
        # These get created once in the `namespaces` phase (order -5),
        # before any component phases run.
        allNamespaces = lib.unique (
          lib.concatLists (
            lib.mapAttrsToList (
              _: phaseCfg: lib.concatMap (b: b.createNamespaces) (lib.attrValues phaseCfg.bundles)
            ) config.phases
          )
        );

        # Pod Security Admission labels for namespaces
        psaCfg = config.cluster.security.podSecurity;
        psaLabels =
          ns:
          let
            level = psaCfg.namespaceOverrides.${ns} or psaCfg.default;
          in
          if psaCfg.enable then
            {
              "pod-security.kubernetes.io/enforce" = level;
              "pod-security.kubernetes.io/warn" = level;
            }
          else
            { };

        namespaceYamls = map (
          ns:
          let
            labels = psaLabels ns;
          in
          builtins.toJSON (
            {
              apiVersion = "v1";
              kind = "Namespace";
              metadata.name = ns;
            }
            // lib.optionalAttrs (labels != { }) {
              metadata = {
                name = ns;
                labels = labels;
              };
            }
          )
        ) allNamespaces;

        # Check if any secret projections target a given phase.
        # Projections are CLI-injected (not rendered), but the phase must exist
        # in the output so the CLI knows to run injection at the right point.
        projectionPhases = lib.unique (map (proj: proj.phase) (lib.attrValues config.secrets.projections));

        mergePhase =
          phaseName: phaseCfg:
          let
            bundleValues = lib.attrValues phaseCfg.bundles;
            allHelmCharts = lib.foldl' (acc: b: acc // b.helmCharts) { } bundleValues;
            allResources = lib.foldl' (acc: b: acc // b.resources) { } bundleValues;
            allYamls = lib.concatMap (b: b.yamls) bundleValues;

            # For the namespaces phase, include all collected namespace YAMLs
            phaseYamls = if phaseName == "namespaces" then allYamls ++ namespaceYamls else allYamls;

            hasContent = allHelmCharts != { } || allResources != { } || phaseYamls != [ ];
            hasProjections = builtins.elem phaseName projectionPhases;
          in
          if hasContent || hasProjections then
            {
              inherit (phaseCfg)
                order
                dependsOn
                keepResources
                pruneStrategy
                waitForReady
                timeout
                waitForCRDs
                crdNames
                ;
              package = render.renderPhase phaseName {
                helmCharts = allHelmCharts;
                resources = allResources;
                yamls = phaseYamls;
              };
            }
          else
            null;

        allPhases = lib.mapAttrs mergePhase config.phases;
      in
      lib.filterAttrs (_: v: v != null) allPhases;

    phaseOrder = lib.sort (
      a: b: config.cluster.out.phases.${a}.order < config.cluster.out.phases.${b}.order
    ) (lib.attrNames config.cluster.out.phases);
  };

}

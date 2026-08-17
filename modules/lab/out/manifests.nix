# The three rendered manifest trees a lab produces: the steady-state one Argo
# reconciles, the bootstrap one the CLI applies before Argo exists, and the
# stage-1 subset that a pivot needs before the management cluster does.
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

  # The probe images a lowered http/tcp/dns readyProbe runs come from lab
  # config, the same as the ones a floe's own waiter uses.
  renderers = import ../../../lib/render {
    inherit lib pkgs;
    waitImages = lib.mapAttrs (_: i: i.ref) config.lab.images.wait;
  };
  catallaxyLib = import ../../../lib/eval/cluster.nix { inherit lib pkgs; };

  # Read once here rather than in each renderer. A missing file is an eval
  # error, so `lockFile = null` is what a lab that has not generated one yet
  # relies on.
  imageLock =
    if config.lab.images.lockFile == null then
      { }
    else
      builtins.fromJSON (builtins.readFile config.lab.images.lockFile);

  imageRegistry = config.lab.images.registry;

  # Every declared image the lab moved, as the string in the manifest paired
  # with the string it should become.
  #
  # Most declared images are a chart's, and reach the manifest as the chart's
  # own default rather than through anything the floe wrote, so a lab that
  # overrides one has nothing to set. Rewriting the rendered file is what
  # makes `lab.images.pinned` reach those, and it is why the declaration
  # carries what the floe originally said.
  imageMovesFor =
    clusterCfg:
    lib.concatLists (
      lib.mapAttrsToList (
        _: floeCfg:
        lib.mapAttrsToList (_: image: {
          from = image.declaredRef;
          to = image.ref;
        }) (lib.filterAttrs (_: i: i.declaredRef != i.ref) (floeCfg.images or { }))
      ) clusterCfg.floes
    );

  # Two floes can declare the same image, and a rewrite keyed by the string
  # in the file cannot tell their copies apart. Overriding one and not the
  # other is therefore not something this can honour, and saying so is better
  # than moving both and looking like it worked.
  imageOverridesFor =
    clusterCfg:
    let
      moves = imageMovesFor clusterCfg;
      byFrom = lib.groupBy (m: m.from) moves;
      conflicting = lib.filterAttrs (_: ms: (lib.length (lib.unique (map (m: m.to) ms))) > 1) byFrom;
    in
    if conflicting != { } then
      throw ''
        Two floes on cluster ${clusterCfg.cluster.name} declare the same image and
        lab.images.pinned sends their copies to different places:

        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            from: ms: "  ${from} -> ${lib.concatStringsSep ", " (lib.unique (map (m: m.to) ms))}"
          ) conflicting
        )}

        The rewrite matches on the reference in the rendered file, so both
        copies would move together. Pin them to the same reference, or leave
        one alone.
      ''
    else
      lib.listToAttrs (map (m: lib.nameValuePair m.from m.to) moves);

  # And whatever a pin settled, the blanket registry must not move.
  #
  # Keyed on a pin existing rather than on the reference having changed,
  # because pinning an image back to the registry the floe already named
  # changes nothing and is still the lab saying where that image comes from.
  imageExemptFor =
    clusterCfg:
    lib.unique (
      lib.concatLists (
        lib.mapAttrsToList (
          floeName: floeCfg:
          lib.mapAttrsToList (_: image: image.ref) (
            lib.filterAttrs (label: _: (config.lab.images.pinned.${floeName}.${label} or null) != null) (
              floeCfg.images or { }
            )
          )
        ) clusterCfg.floes
      )
    );

  wavesForView =
    view: waves:
    let
      keep = b: view.packages ? ${b.name} || lib.hasPrefix "projection/" b.name;
    in
    lib.filter (w: w != [ ]) (map (w: lib.filter keep w) waves);
in
{
  options.lab.out = {
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

    manifestViews = mkOption {
      type = types.attrsOf types.raw;
      readOnly = true;
      internal = true;
      description = ''
        Per-cluster bundle view that `manifests` was rendered from.

        Which of the three views a cluster gets depends on the CD strategy
        and whether owner filtering is on. Anything that has to reason about
        what `manifests` contains reads this rather than repeating that
        choice, because a copy that drifts by one branch attributes a
        rendered file to a bundle the lab does not deploy.
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

  };

  config.lab.out = {
    manifestViews =
      let
        strategy = config.lab.cd.strategy;
        useFiltering = config.lab.cd.useOwnerFiltering;
      in
      lib.mapAttrs (
        _: clusterCfg:
        if !useFiltering then
          clusterCfg.cluster.out.bundleView
        else if strategy == "kapp" then
          clusterCfg.cluster.out.imperativeBundleView
        else
          clusterCfg.cluster.out.argocdBundleView
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
        let
          view = config.lab.out.manifestViews.${name};
          filteredWaves = wavesForView view clusterCfg.cluster.out.manifestWaves;
        in
        renderer (
          {
            clusterName = name;
            inherit prefix imageLock imageRegistry;
            imageExempt = imageExemptFor clusterCfg;
            imageOverrides = imageOverridesFor clusterCfg;
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
            inherit prefix imageLock imageRegistry;
            imageExempt = imageExemptFor clusterCfg;
            imageOverrides = imageOverridesFor clusterCfg;
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
              inherit prefix imageLock imageRegistry;
              imageExempt = imageExemptFor clusterCfg;
              imageOverrides = imageOverridesFor clusterCfg;
              inherit (view) packages;
              labNamespaces = config.lab.out.labNamespaces.${name};
              deployConfig = config.lab.cd.kapp;
              waves = wavesForView view clusterCfg.cluster.out.manifestWaves;
            }
        ) config.lab.out.allClusters
      );

  };
}

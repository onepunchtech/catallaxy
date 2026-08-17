{ lib }:

let
  sanitize = key: builtins.replaceStrings [ "/" ] [ "__" ] key;

  structuralDirs = [
    "bundles"
    "applications"
    "bootstrap"
  ];

  floeRef = name: version: if version == null then "floe/${name}" else "floe/${name}@${version}";

  enabledFloes = cluster: lib.filterAttrs (_: f: f.enable or false) cluster.floes;

  refOfFloe =
    cluster: name:
    let
      floes = enabledFloes cluster;
    in
    if floes ? ${name} then floeRef name (floes.${name}.version or null) else null;

  bundleTable =
    cluster:
    lib.mapAttrs' (
      key: _:
      lib.nameValuePair (sanitize key) (
        let
          floeName = cluster.view.bundles.${key}.floe or null;
        in
        if floeName == null then null else refOfFloe cluster floeName
      )
    ) cluster.view.packages;

  chartsOf =
    cluster:
    lib.concatLists (
      lib.mapAttrsToList (
        key: bundle:
        lib.mapAttrsToList (chartKey: spec: {
          key = chartKey;
          floeRef =
            let
              floeName = bundle.floe or null;
            in
            if floeName == null then null else refOfFloe cluster floeName;
          path = toString spec.chart;
        }) (bundle.helmCharts or { })
      ) cluster.view.bundles
    );

  floeComponents =
    clusters:
    lib.unique (
      lib.concatMap (
        cluster:
        lib.mapAttrsToList (name: f: {
          ref = floeRef name (f.version or null);
          inherit name;
          version = f.version or null;
        }) (enabledFloes cluster)
      ) clusters
    );
in
{
  inherit sanitize floeRef structuralDirs;

  collisionsOf =
    clusters:
    lib.unique (
      lib.concatMap (
        cluster:
        lib.filter (d: builtins.elem d structuralDirs) (map sanitize (lib.attrNames cluster.view.packages))
      ) clusters
    );

  evalInput = { labName, clusters }: {
    lab.name = labName;
    floes = floeComponents clusters;
    clusters = map (cluster: {
      inherit (cluster) tree;
      bundles = bundleTable cluster;
      charts = chartsOf cluster;
    }) clusters;
  };
}

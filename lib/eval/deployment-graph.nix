{ lib }:

let
  inherit (lib)
    mapAttrsToList
    filter
    map
    concatMap
    ;

  localProvisioners = [
    "k3d"
    "talos"
  ];
in
{

  computeGraph =
    clusters:
    let
      allClusters = mapAttrsToList (name: clusterCfg: {
        inherit name;
        provisioner = clusterCfg.cluster.provisioner;
        config = clusterCfg;
      }) clusters;

      clustersByProvisioner = provisioner: filter (c: c.provisioner == provisioner) allClusters;

      localClusters = filter (c: builtins.elem c.provisioner localProvisioners) allClusters;

      provisionedElsewhere = map (c: c.name) (
        filter (c: !(builtins.elem c.provisioner localProvisioners)) allClusters
      );

      provisionerGraph = map (
        c:
        let
          declared = lib.attrNames c.config.cluster.provisions;
        in
        {
          source = c;
          targets = filter (n: builtins.elem n provisionedElsewhere || n == c.name) declared;
          isSelfProvisioning = builtins.elem c.name declared;
        }
      ) (filter (c: c.config.cluster.provisions != { }) localClusters);

      syncedContextClusterNames = lib.unique (concatMap (e: e.targets) provisionerGraph);

      syncedContextFor =
        clusterName: if builtins.elem clusterName syncedContextClusterNames then clusterName else null;
    in
    {
      inherit
        allClusters
        clustersByProvisioner
        localClusters
        provisionerGraph
        syncedContextClusterNames
        syncedContextFor
        ;
    };
}

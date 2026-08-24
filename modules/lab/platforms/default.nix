{ config, lib, ... }:

let
  # A platform floe says which clusters it stood up by exporting `clusters`.
  # Nothing registers as a platform: exporting that list is what makes one, so
  # a floe an operator writes outside this repo is checked the same way.
  claimants = lib.filterAttrs (
    _: floe: (floe.enable or false) && (floe.exports or { }) ? clusters
  ) config.lab.floes;

  claimedBy = lib.foldl' (
    acc: name:
    lib.foldl' (
      inner: cluster: inner // { ${cluster} = (inner.${cluster} or [ ]) ++ [ name ]; }
    ) acc claimants.${name}.exports.clusters
  ) { } (lib.attrNames claimants);

  contested = lib.filterAttrs (_: names: lib.length names > 1) claimedBy;
in
{
  imports = [
    ./k3d-local.nix
    ./talos-local.nix
  ];

  options.lab.platforms.contestedClusters = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    description = ''
      Clusters more than one enabled platform floe claims, which no platform
      may configure.

      A platform floe subtracts these from the clusters it acts on. Without
      that, two of them set the same cluster's provisioner and the module
      system reports a conflicting definition on whichever option is forced
      first, which is a message naming two files and no floes, and it
      arrives before the assertion below gets to say anything.

      Read it rather than deciding for yourself which clusters are safe: a
      floe written outside this repo consults the same list, and gets the
      same refusal, without importing anything.
    '';
  };

  config.lab.platforms.contestedClusters = lib.attrNames contested;

  config.lab.assertions = lib.mapAttrsToList (cluster: names: {
    assertion = false;
    message = ''
      cluster '${cluster}' is claimed by ${
        lib.concatStringsSep " and " (map (n: "`lab.floes.${n}`") names)
      }.

      A cluster runs on one platform. Two of them set its provisioner and its
      network, and the module system reports that as a conflict on whichever
      option it reaches first, which says nothing about the two floes that
      disagree.

      Drop the cluster from one of their `clusters` lists. A lab runs two
      platforms by giving each its own clusters, not by giving one cluster
      both.
    '';
  }) contested;
}

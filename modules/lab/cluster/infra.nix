{ config, lib, ... }:

let
  infraTypes = import ../../../lib/infra/types.nix { inherit lib; };
  inherit (import ../../../lib/floe/collisions.nix { inherit lib; }) contestedKeys;

  enabledFloes = lib.filterAttrs (_: floe: floe.enable or false) config.floes;

  contested = contestedKeys {
    floes = config.floes;
    keysOf = floe: lib.attrNames (floe.infra.resources or { });
  };
in
{
  options.infra.resources = lib.mkOption {
    type = lib.types.attrsOf infraTypes.resourceType;
    default = { };
    description = ''
      Infrastructure this cluster needs provisioned, folded into the lab's
      stacks with this cluster's name prefixed.

      Written by the cluster and by modules that are not floes; an enabled
      floe's `floes.<n>.infra.resources` are merged in here.

      Prefixed on the way up because a stack is one namespace across the
      whole lab: two clusters each asking for a `backups` bucket are two
      buckets, and only the lab-level name can say which is which.
    '';
  };

  # A contested name is left out rather than merged. `inputs` holds raw
  # values, which refuse a second definition, so merging both would fail on
  # whichever input the two floes happen to share and name this file twice
  # and neither floe. With no second definition the assertion below is what
  # reports.
  config.infra.resources = lib.mkMerge (
    lib.mapAttrsToList (
      _: floe: removeAttrs floe.infra.resources (lib.attrNames contested)
    ) enabledFloes
  );

  config.assertions = lib.mapAttrsToList (name: claimants: {
    assertion = false;
    message = ''
      infra resource '${name}' on cluster '${config.cluster.name}' is
      declared by ${lib.concatStringsSep " and " (map (n: "`floes.${n}`") claimants)}.

      A resource name is its identity in the stack's state, so the second
      one does not add a resource, it collides with the first on whichever
      input the two disagree about.

      Rename one. Nothing reaches a resource by a name it did not choose:
      a reference names it explicitly.
    '';
  }) contested;
}

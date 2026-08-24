{ config, lib, ... }:

let
  inherit (import ../planner/types.nix { inherit lib; }) clusterStepType;
  inherit (import ../../../lib/floe/collisions.nix { inherit lib; }) contestedKeys;

  enabledFloes = lib.filterAttrs (_: floe: floe.enable or false) config.floes;

  contested = contestedKeys {
    floes = config.floes;
    keysOf = floe: lib.attrNames (floe.steps or { });
  };
in
{
  options.steps = lib.mkOption {
    type = lib.types.attrsOf clusterStepType;
    default = { };
    description = ''
      Plan steps this cluster contributes. Folded into `lab.steps` as
      `<cluster>-<name>`, with `cluster` set to this cluster unless the
      step sets `scope = "lab"`.

      Written directly by the cluster and by modules that are not floes; an
      enabled floe's `floes.<n>.steps` are merged in here, carrying an
      `origin` that names the floe.

      Because the fold renames the attr key, an `after` / `before` entry
      targeting a sibling declared here must go through a
      `provides:<token>` or `kind:<kind>` anchor rather than the
      sibling's bare name; the bare name no longer exists by the time
      `topoSort` resolves anchors.
    '';
  };

  config.steps = lib.mkMerge (
    lib.mapAttrsToList (
      floeName: floe:
      lib.mapAttrs (
        stepName: step:
        step // { origin = "clusters.${config.cluster.name}.floes.${floeName}.steps.${stepName}"; }
      ) floe.steps
    ) enabledFloes
  );

  config.assertions = lib.mapAttrsToList (stepName: claimants: {
    assertion = false;
    message = ''
      step '${stepName}' on cluster '${config.cluster.name}' is declared by ${
        lib.concatStringsSep " and " (map (n: "`floes.${n}`") claimants)
      }.

      Steps are lifted into one namespace per cluster, so the second one
      does not merge with the first, it collides with it on whichever field
      the two happen to disagree about, and the module system reports that
      without naming either floe.

      Rename one. A step's key is not how anything reaches it: what another
      step waits on is a token in `provides`, which both may publish.
    '';
  }) contested;
}

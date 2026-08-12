{ lib, ... }:

let
  inherit (import ../planner/types.nix { inherit lib; }) clusterStepType;
in
{
  options.steps = lib.mkOption {
    type = lib.types.attrsOf clusterStepType;
    default = { };
    description = ''
      Plan steps this cluster contributes. Folded into `lab.steps` as
      `<cluster>-<name>`, with `cluster` set to this cluster unless the
      step sets `scope = "lab"`.

      Because the fold renames the attr key, an `after` / `before` entry
      targeting a sibling declared here must go through a
      `provides:<token>` or `kind:<kind>` anchor rather than the
      sibling's bare name; the bare name no longer exists by the time
      `topoSort` resolves anchors.
    '';
  };
}

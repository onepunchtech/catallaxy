{ lib }:

{
  inherit (import ./mk-floe.nix { inherit lib; }) mkFloe;
  inherit (import ./eval-floe.nix { inherit lib; }) evalFloe;
  refs = import ./refs.nix { inherit lib; };
}

{ lib }:

{
  inherit (import ../../modules/lab/cluster/floe-options.nix { inherit lib; }) floeOptions;
  inherit (import ../../modules/lab/lab-floe-options.nix { inherit lib; }) labFloeOptions;
  inherit (import ./eval-floe.nix { inherit lib; }) evalFloe;
  inherit (import ./gateway-options.nix { inherit lib; }) gatewayOptions;
  refs = import ./refs.nix { inherit lib; };
}

{ lib, pkgs }:

let
  evalMod = import ./eval-module.nix { inherit lib; };
  eval = import ./eval.nix { inherit lib pkgs; };
  network = import ./network.nix { inherit lib; };
  checks = import ./checks.nix { inherit lib pkgs; };
  render = import ./render.nix { inherit lib pkgs; };
  renderers = import ./renderers { inherit lib pkgs; };
in
{
  inherit (evalMod) evalModule;

  inherit network;

  inherit (eval)
    evalCluster
    evalClusterConfig
    evalClusterJSON
    clusterConfigToJSON
    baseModules
    ;

  inherit checks;

  # Build-time manifest rendering (renderPhase, renderHelmChart, etc.)
  inherit render;

  inherit renderers;
}

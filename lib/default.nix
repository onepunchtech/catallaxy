# lib/default.nix
#
# Main entry point for the catallaxy library.
# Provides module evaluation, manifest rendering, and strategy-specific renderers.

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
  # General-purpose module evaluator with assertion checking
  inherit (evalMod) evalModule;

  # Network utilities
  inherit network;

  # Module evaluation (for introspection, CLI, etc.)
  inherit (eval)
    evalCluster
    evalClusterConfig
    evalClusterJSON
    clusterConfigToJSON
    baseModules
    ;

  # Check helpers for manifest validation
  inherit checks;

  # Build-time manifest rendering (renderPhase, renderHelmChart, etc.)
  inherit render;

  # Strategy-specific manifest renderers (kapp, argocd, fleet)
  inherit renderers;
}

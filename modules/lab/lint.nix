{ lib, ... }:

{
  options.lab.lint.checks = lib.mkOption {
    type = lib.types.attrsOf (import ./lint-types.nix { inherit lib; }).checkType;
    default = { };
    description = ''
      Checks about this lab's rendered manifests, run by `cata lab lint`
      beside the built-in ones. A check here applies to every cluster.

      A floe declares the same shape at `floes.<n>.lint.<name>`, which is
      usually where it belongs: the component knows what a wrong rendering of
      itself looks like, and every lab enabling it inherits the check.
    '';
  };
}

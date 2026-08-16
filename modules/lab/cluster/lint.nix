{
  config,
  lib,
  lab,
  ...
}:

let
  lintTypes = import ../lint-types.nix { inherit lib; };

  # Gated on enable: a check about manifests a disabled floe did not render
  # has nothing to look at, and a lab can write `floes.<n>.lint.<name>`
  # without enabling the floe.
  floeChecks = lib.concatMapAttrs (
    floeName: floe:
    lib.optionalAttrs (floe.enable or false) (
      lib.mapAttrs' (checkName: check: lib.nameValuePair "${floeName}-${checkName}" check) (
        floe.lint or { }
      )
    )
  ) config.floes;

  allChecks = floeChecks // (lab.lint.checks or { }) // config.lint.checks;
in
{
  options.lint.checks = lib.mkOption {
    type = lib.types.attrsOf lintTypes.checkType;
    default = { };
    description = ''
      Checks about this cluster's rendered manifests, run by `cata lab lint`
      alongside the lab's and the enabled floes'.
    '';
  };

  options.lint.out.checks = lib.mkOption {
    internal = true;
    readOnly = true;
    type = lib.types.attrsOf lib.types.attrs;
    description = "Every check that applies to this cluster: the floes', the lab's, and this cluster's own.";
  };

  config.lint.out.checks = allChecks;
}

{ lib, ... }:

let
  inherit (lib) mkOption types;
in
{
  imports = [
    ./types.nix
    ./host
    ./network
    ./ops
    ./trust
    ./secrets
    ./images.nix
    ./lint.nix
    ./verify.nix
    ./e2e.nix
    ./planner
    ./out.nix
  ];

  options.lab.assertions = mkOption {
    type = types.listOf (
      types.submodule {
        options = {
          assertion = mkOption { type = types.bool; };
          message = mkOption { type = types.str; };
        };
      }
    );
    default = [ ];
    description = ''
      Hard config-validity checks at lab scope. Failed entries block
      `cata lab up`. For per-cluster constraints, set
      `lab.clusters.<n>.assertions` instead; that way the constraint
      travels with the module that owns it.
    '';
  };

  options.lab.warnings = mkOption {
    type = types.listOf types.str;
    default = [ ];
    description = ''
      Soft config-validity advisories at lab scope. Surfaced by
      `cata lint` and `cata lab up` but do not block deployment.
    '';
  };
}

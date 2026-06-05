# Lab-level lint configuration — extensible property checks on rendered manifests.
#
# Users declare custom lint checks as shell commands that run per YAML file.
# Built-in checks (Rust) run alongside custom checks during `cata lab lint`.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkOption types mapAttrs;

  checkType = types.submodule {
    options = {
      description = mkOption {
        type = types.str;
        description = "Human-readable description of what this check validates";
      };

      severity = mkOption {
        type = types.enum [
          "error"
          "warning"
        ];
        default = "warning";
        description = "Error = fails the lint, Warning = reported but doesn't fail";
      };

      command = mkOption {
        type = types.str;
        description = ''
          Shell command to execute per YAML file.
          Environment variables:
            $FILE    — path to the YAML manifest file
            $CLUSTER — name of the cluster being checked
          Exit 0 = pass, non-zero = fail.
          Stdout = diagnostic message (shown to user on failure).
        '';
      };
    };
  };
in
{
  options.lab.lint = {
    checks = mkOption {
      type = types.attrsOf checkType;
      default = { };
      description = ''
        Custom lint checks that run on rendered manifests.
        Each check is a shell command executed per YAML file.
        Checks run alongside built-in checks during `cata lab lint`.
      '';
    };
  };
}

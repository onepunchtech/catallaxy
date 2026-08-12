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

      scope = mkOption {
        type = types.enum [
          "per-file"
          "per-cluster"
        ];
        default = "per-file";
        description = ''
          When the check runs.
            per-file    - once per YAML manifest ($FILE + $CLUSTER set).
                          Retained for backwards compatibility; costly on
                          large labs (N files × M checks invocations).
            per-cluster - once per cluster ($CLUSTER + $MANIFEST_DIR set).
                          The script is responsible for walking the
                          manifest tree itself; usually faster and lets
                          the check reason across files.
        '';
      };

      format = mkOption {
        type = types.enum [
          "exit-code"
          "json"
        ];
        default = "exit-code";
        description = ''
          How diagnostics come out of the script.
            exit-code - non-zero exit = fail; stdout is the diagnostic
                        message. Severity + resource come from this
                        option and the file/cluster the check ran on.
            json      - stdout is a JSON array of diagnostics:
                          [{ "severity": "error"|"warning",
                             "resource": "...",
                             "message": "..." }]
                        Empty array = pass. Exit code is ignored.
                        Lets one script emit multiple structured
                        findings with per-diagnostic severity.
        '';
      };

      command = mkOption {
        type = types.str;
        description = ''
          Shell command to execute. See `scope` for env vars.
          exit-code format: non-zero = fail, stdout = message.
          json format: stdout = JSON diagnostic array.
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

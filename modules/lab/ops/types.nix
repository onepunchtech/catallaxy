{ lib }:

let
  inherit (lib) mkOption types;
in
{
  optionType = types.submodule {
    options = {
      type = mkOption {
        type = types.enum [
          "string"
          "enum"
          "bool"
        ];
        default = "string";
      };
      description = mkOption {
        type = types.str;
        default = "";
      };
      required = mkOption {
        type = types.bool;
        default = false;
      };
      default = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      values = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Valid values for enum type";
      };
    };
  };

  argType = types.submodule {
    options = {
      name = mkOption { type = types.str; };
      description = mkOption {
        type = types.str;
        default = "";
      };
      required = mkOption {
        type = types.bool;
        default = true;
      };
    };
  };

  opsCommandType =
    { optionType, argType }:
    types.submodule {
      options = {
        description = mkOption {
          type = types.str;
          description = "One-line description shown in help";
        };
        category = mkOption {
          type = types.str;
          default = "general";
          description = "Subcommand group (e.g. 'backup', 'database')";
        };
        options = mkOption {
          type = types.attrsOf optionType;
          default = { };
          description = "Named options (flags)";
        };
        args = mkOption {
          type = types.listOf argType;
          default = [ ];
          description = "Positional arguments";
        };
        package = mkOption {
          type = types.package;
          description = "Package providing the command binary";
        };

        cluster = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Named cluster this ops command targets. When set, the CLI
            exports `KUBECONTEXT` into the subprocess env with the
            cluster's runtime kubectl context (from
            `lab.out.runtimeContexts.<cluster>`). Scripts should use
            `$KUBECONTEXT` directly; the wrapping CLI handles pivot
            state and provisioner-specific context naming.
          '';
        };
      };
    };
}

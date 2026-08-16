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
        description = ''
          How the flag is parsed. `bool` takes no value and is present or
          absent; `enum` is validated against `values`.
        '';
      };
      description = mkOption {
        type = types.str;
        default = "";
        description = "One-line help text, shown beside the flag.";
      };
      required = mkOption {
        type = types.bool;
        default = false;
        description = "Whether the generated tool refuses to run without it.";
      };
      default = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Value used when the flag is not passed.";
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
      name = mkOption {
        type = types.str;
        description = "Placeholder shown in the usage line, e.g. `CLUSTER`.";
      };
      description = mkOption {
        type = types.str;
        default = "";
        description = "One-line help text for this argument.";
      };
      required = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether the generated tool refuses to run without it. Positional
          arguments are required by default, unlike flags.
        '';
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

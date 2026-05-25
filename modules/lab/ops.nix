# modules/lab/ops.nix
#
# Lab operations — component-aware runtime tooling.
#
# Generates a lab-specific CLI tool (<labname>-ops) from declared
# operational commands. Components can contribute commands automatically
# (e.g., kanidm ships a password reset command), and users can add their
# own alongside their lab config.
#
# Each command is a Nix package (typically writeShellApplication) that
# conforms to a simple interface. The ops module wraps them into a
# multi-command dispatcher with self-documenting --help.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkOption
    mkEnableOption
    types
    mkIf
    mapAttrsToList
    concatStringsSep
    concatMapAttrs
    ;

  cfg = config.lab.ops;

  # Command submodule type
  opsCommandType = types.submodule {
    options = {
      description = mkOption {
        type = types.str;
        description = "One-line description shown in --help";
      };
      category = mkOption {
        type = types.str;
        default = "general";
        description = "Category for grouping in help output";
      };
      args = mkOption {
        type = types.listOf (
          types.submodule {
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
          }
        );
        default = [ ];
        description = "Positional arguments for the command";
      };
      package = mkOption {
        type = types.package;
        description = "Package providing the command binary (name must match command name)";
      };
    };
  };

  # Collect component-contributed ops from all clusters
  componentOps = concatMapAttrs (
    clusterName: clusterCfg:
    let
      clusterOps = clusterCfg.ops or { };
    in
    lib.mapAttrs (
      name: cmd:
      cmd
      // {
        category = cmd.category or clusterName;
      }
    ) clusterOps
  ) config.lab.out.allClusters;

  # Merge: component ops as defaults, user commands override
  allCommands = componentOps // cfg.commands;

  # Generate the dispatcher script
  toolScript =
    let
      # Case branches for each command
      caseBranches = concatStringsSep "\n" (
        mapAttrsToList (
          name: cmd:
          let
            binName = builtins.replaceStrings [ "-" ] [ "-" ] name;
          in
          ''
            ${name})
              shift
              exec ${cmd.package}/bin/${binName} "$@"
              ;;''
        ) allCommands
      );

      # Help text
      helpLines = concatStringsSep "\n" (
        mapAttrsToList (name: cmd: ''printf "  %-24s %s\n" "${name}" "${cmd.description}"'') allCommands
      );

      # Args help for individual commands
      argsHelp = concatStringsSep "\n" (
        mapAttrsToList (
          name: cmd:
          if cmd.args != [ ] then
            let
              argNames = concatStringsSep " " (
                map (a: if a.required then "<${a.name}>" else "[${a.name}]") cmd.args
              );
            in
            ''
              ${name})
                echo "Usage: ${config.lab.name}-ops ${name} ${argNames}"
                echo ""
                echo "  ${cmd.description}"
                ${concatStringsSep "\n" (map (a: ''echo "  ${a.name}: ${a.description}"'') cmd.args)}
                ;;''
          else
            ""
        ) allCommands
      );
    in
    ''
      case "''${1:-}" in
      ${caseBranches}
          help)
            if [ -n "''${2:-}" ]; then
              case "$2" in
      ${argsHelp}
                *)
                  echo "Unknown command: $2"
                  ;;
              esac
            else
              echo "Lab operations for '${config.lab.name}'"
              echo ""
              echo "Commands:"
      ${helpLines}
              echo ""
              echo "Run '${config.lab.name}-ops help <command>' for details"
            fi
            ;;
          --help|-h|"")
            echo "Lab operations for '${config.lab.name}'"
            echo ""
            echo "Commands:"
      ${helpLines}
            echo ""
            echo "Run '${config.lab.name}-ops help <command>' for details"
            ;;
          *)
            echo "Unknown command: $1"
            echo "Run '${config.lab.name}-ops --help' for usage"
            exit 1
            ;;
      esac
    '';
in
{
  options.lab.ops = {
    commands = mkOption {
      type = types.attrsOf opsCommandType;
      default = { };
      description = ''
        Operational commands for the lab. Each command is a package that
        implements a specific runtime operation (password resets, DB shells,
        secret rotation, etc.).

        Components can contribute commands automatically via cluster-level
        `ops.<name>` options. User-defined commands here take priority.
      '';
    };

    out = {
      tool = mkOption {
        type = types.nullOr types.package;
        readOnly = true;
        description = "Generated lab operations CLI tool (null if no commands defined)";
      };
    };
  };

  config.lab.ops.out.tool =
    if allCommands != { } then
      pkgs.writeShellApplication {
        name = "${config.lab.name}-ops";
        text = toolScript;
      }
    else
      null;
}

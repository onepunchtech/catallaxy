{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkOption
    types
    mapAttrsToList
    concatStringsSep
    concatMapAttrs
    nameValuePair
    unique
    flatten
    groupBy
    mapAttrs
    mapAttrs'
    filterAttrs
    hasAttr
    attrNames
    attrValues
    head
    ;

  cfg = config.lab.ops;

  opsTypes = import ./types.nix { inherit lib; };
  inherit (opsTypes) optionType argType;
  opsCommandType = opsTypes.opsCommandType { inherit optionType argType; };

  allClusterOps =
    let
      tuples = flatten (
        mapAttrsToList (
          clusterName: clusterCfg:
          let
            clusterOps = clusterCfg.ops or { };
          in
          mapAttrsToList (name: cmd: {
            inherit name clusterName;
            cmd = cmd;
          }) clusterOps
        ) config.lab.out.allClusters
      );
    in
    groupBy (t: t.name) tuples;

  mergedClusterOps = mapAttrs (
    name: entries:
    let
      first = (head entries).cmd;
      clusterNames = map (e: e.clusterName) entries;
      isSingleCluster = builtins.length entries == 1;

      mergedOptions =
        let
          allOptionNames = unique (flatten (map (e: attrNames e.cmd.options) entries));
          mergeOption =
            optName:
            let

              optInstances = builtins.filter (e: hasAttr optName e.cmd.options) entries;
              firstOpt = (head optInstances).cmd.options.${optName};
            in
            if firstOpt.type == "enum" then
              firstOpt
              // {
                values = unique (flatten (map (e: e.cmd.options.${optName}.values) optInstances));
              }
            else
              firstOpt;
        in
        builtins.listToAttrs (map (n: nameValuePair n (mergeOption n)) allOptionNames);

      clusterOption = {
        type = "enum";
        values = clusterNames;
        required = !isSingleCluster;
        default = if isSingleCluster then head clusterNames else null;
        description = "Target cluster";
      };

      finalOptions = {
        cluster = clusterOption;
      }
      // mergedOptions;

      packages = builtins.listToAttrs (map (e: nameValuePair e.clusterName e.cmd.package) entries);
    in
    {
      description = first.description;
      category = first.category;
      options = finalOptions;
      args = first.args;
      inherit packages isSingleCluster;
    }
  ) allClusterOps;

  userOps = mapAttrs (name: cmd: {
    inherit (cmd) description category args;
    options = cmd.options or { };
    packages = { };
    isSingleCluster = false;
    userCommand = true;
    package = cmd.package;
    cluster = cmd.cluster or null;
  }) cfg.commands;

  allCommands = mergedClusterOps // userOps;

  commandsByCategory =
    let
      entries = mapAttrsToList (name: cmd: {
        inherit name;
        inherit (cmd) description category;
        cmd = cmd;
      }) allCommands;
    in
    groupBy (e: e.category) entries;

  categoryNames = attrNames commandsByCategory;

  labName = config.lab.name;

  shellVar = n: "OPT_${builtins.replaceStrings [ "-" ] [ "_" ] n}";

  mkFlagParser =
    cmd:
    let
      optNames = attrNames (cmd.options or { });

      initVars = concatStringsSep "\n" (
        map (
          n:
          let
            opt = cmd.options.${n};
            defaultVal = if opt.default != null then opt.default else "";
            var = shellVar n;
          in
          "export ${var}=\"${defaultVal}\""
        ) optNames
      );
      caseBranches = concatStringsSep "\n" (
        map (
          n:
          let
            opt = cmd.options.${n};
            var = shellVar n;
          in
          if opt.type == "bool" then
            "--${n}) export ${var}=true; shift ;;"
          else
            ''--${n}) export ${var}="$2"; shift 2 ;;''
        ) optNames
      );

      validations = concatStringsSep "\n" (
        builtins.filter (s: s != "") (
          map (
            n:
            let
              opt = cmd.options.${n};
              var = shellVar n;
              enumHelp =
                if opt.type == "enum" && opt.values != [ ] then " (${concatStringsSep ", " opt.values})" else "";
            in
            if opt.required then

              "if [ -z \"${"$" + "{${var}}"}\" ]; then echo \"Error: --${n} is required${enumHelp}\"; exit 1; fi"
            else
              ""
          ) optNames
        )
      );

      enumValidations = concatStringsSep "\n" (
        builtins.filter (s: s != "") (
          map (
            n:
            let
              opt = cmd.options.${n};
              var = shellVar n;
              validValues = concatStringsSep "|" opt.values;
              varRef = "$" + "{${var}}";
            in
            if opt.type == "enum" && opt.values != [ ] then
              ''
                if [ -n "${varRef}" ]; then
                  case "${varRef}" in
                    ${validValues}) ;;
                    *) echo "Error: --${n} must be one of: ${concatStringsSep ", " opt.values}"; exit 1 ;;
                  esac
                fi''
            else
              ""
          ) optNames
        )
      );
    in
    {
      parse =
        if optNames == [ ] then
          ""
        else
          ''
            ${initVars}
            while [[ $# -gt 0 ]]; do
              case "$1" in
            ${caseBranches}
                        --help|-h) SHOW_HELP=true; break ;;
                        *) break ;;
              esac
            done'';
      validate =
        if optNames == [ ] then
          ""
        else
          ''
            ${enumValidations}
            ${validations}'';
    };

  mkExecDispatch =
    name: cmd:
    if cmd ? userCommand then

      let
        binName = builtins.replaceStrings [ "-" ] [ "-" ] name;
        clusterCtx =
          if cmd ? cluster && cmd.cluster != null then
            config.lab.out.runtimeContexts.${cmd.cluster}
              or (throw "lab.ops.commands.${name}.cluster refers to unknown cluster '${cmd.cluster}'")
          else
            null;
        contextExport =
          if clusterCtx != null then ''export KUBECONTEXT="${clusterCtx}"'' + "\n            " else "";
      in
      "${contextExport}exec ${cmd.package}/bin/${binName} \"$@\""
    else

      let
        clusterBranches = concatStringsSep "\n" (
          mapAttrsToList (
            clusterName: pkg:
            let
              runtimeCtx =
                config.lab.out.runtimeContexts.${clusterName}
                  or (throw "lab.ops: cluster '${clusterName}' has no runtime context");
            in
            ''${clusterName}) export KUBECONTEXT="${runtimeCtx}"; exec ${pkg}/bin/${name} "$@" ;;''
          ) cmd.packages
        );
      in
      ''
        case "$OPT_cluster" in
        ${clusterBranches}
                        *) echo "Error: --cluster is required (${concatStringsSep ", " (attrNames cmd.packages)})"; exit 1 ;;
                      esac'';

  mkCommandHelp =
    catName: name: cmd:
    let
      optHelp = concatStringsSep "\n" (
        mapAttrsToList (
          optName: opt:
          let
            valuesStr =
              if opt.type == "enum" && opt.values != [ ] then
                " <${concatStringsSep "|" opt.values}>"
              else if opt.type == "bool" then
                ""
              else
                " <value>";
            reqStr = if opt.required then " (required)" else "";
          in
          ''echo "  --${optName}${valuesStr}  ${opt.description}${reqStr}"''
        ) (cmd.options or { })
      );
      argHelp = concatStringsSep "\n" (
        map (
          a:
          let
            display = if a.required then "<${a.name}>" else "[${a.name}]";
          in
          ''echo "  ${display}  ${a.description}"''
        ) (cmd.args or [ ])
      );
      argUsage = concatStringsSep " " (
        map (a: if a.required then "<${a.name}>" else "[${a.name}]") (cmd.args or [ ])
      );
      hasOptions = (cmd.options or { }) != { };
      optUsage = if hasOptions then " [OPTIONS]" else "";
    in
    ''
      echo "Usage: ${labName}-ops ${catName} ${name}${optUsage} ${argUsage}"
      echo ""
      echo "  ${cmd.description}"
      ${lib.optionalString hasOptions ''
        echo ""
        echo "Options:"
        ${optHelp}
      ''}
      ${lib.optionalString (cmd.args or [ ] != [ ]) ''
        echo ""
        echo "Arguments:"
        ${argHelp}
      ''}'';

  mkCategoryCase =
    catName: commands:
    let
      commandBranches = concatStringsSep "\n" (
        map (
          entry:
          let
            name = entry.name;
            cmd = entry.cmd;
            parsed = mkFlagParser cmd;
            execDispatch = mkExecDispatch name cmd;
            helpText = mkCommandHelp catName name cmd;
          in
          let
            requiredArgs = builtins.filter (a: a.required) (cmd.args or [ ]);
            requiredArgCount = builtins.length requiredArgs;
            argValidation =
              if requiredArgCount > 0 then
                let
                  argUsage = concatStringsSep " " (
                    map (a: if a.required then "<${a.name}>" else "[${a.name}]") (cmd.args or [ ])
                  );
                in
                ''
                  if [ $# -lt ${toString requiredArgCount} ]; then
                    echo "Error: missing required argument(s)"
                    echo "Usage: ${labName}-ops ${catName} ${name} ${argUsage}"
                    exit 1
                  fi''
              else
                "";
          in
          ''
            ${name})
              shift
              SHOW_HELP=false
              ${parsed.parse}
              if [ "$SHOW_HELP" = true ]; then
                ${helpText}
                exit 0
              fi
              ${parsed.validate}
              ${argValidation}
              ${execDispatch}
              ;;''
        ) commands
      );
      helpLines = concatStringsSep "\n" (
        map (entry: ''printf "  %-24s %s\n" "${entry.name}" "${entry.description}"'') commands
      );
    in
    ''
          ${catName})
            shift
            case "''${1:-}" in
      ${commandBranches}
              --help|-h|"")
                echo "${catName} commands:"
                echo ""
      ${helpLines}
                ;;
              *)
                echo "Unknown ${catName} command: ''${1:-}"
                echo "Run '${labName}-ops ${catName} --help' for usage"
                exit 1
                ;;
            esac
            ;;'';

  toolScript =
    let
      categoryBranches = concatStringsSep "\n" (mapAttrsToList mkCategoryCase commandsByCategory);
      categoryHelp = concatStringsSep "\n" (
        map (
          cat:
          let
            cmds = commandsByCategory.${cat};
            count = builtins.length cmds;
          in
          ''printf "  %-24s %d command(s)\n" "${cat}" ${toString count}''
        ) categoryNames
      );
    in
    ''
      case "''${1:-}" in
      ${categoryBranches}
          --help|-h|"")
            echo "Lab operations for '${labName}'"
            echo ""
            echo "Commands:"
      ${categoryHelp}
            echo ""
            echo "Run '${labName}-ops <command> --help' for details"
            ;;
          *)
            echo "Unknown command: ''${1:-}"
            echo "Run '${labName}-ops --help' for usage"
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
        Lab-global operational commands. These are not cluster-specific
        and appear directly in the ops tool under their category.

        Components contribute cluster-scoped commands via the cluster-level
        `ops.<name>` option. Same-named commands from different clusters
        are automatically merged (enum options get their values unioned).
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

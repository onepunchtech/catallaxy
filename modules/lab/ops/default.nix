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
  inherit (import ../../../lib/render/ops-cli.nix { inherit lib; }) opsToolScript;
  inherit (opsTypes) optionType argType;
  opsCommandType = opsTypes.opsCommandType { inherit optionType argType; };

  # category -> name -> [ { clusterName; cmd; } ]. Two levels, because the
  # invocation is `<lab>-ops <category> <name>` and keying on the name alone
  # made two floes unable to publish the same command under different
  # categories: it collided on the submodule's required fields long before
  # anything got as far as grouping.
  clusterEntries =
    let
      tuples = flatten (
        mapAttrsToList (
          clusterName: clusterCfg:
          flatten (
            mapAttrsToList (
              category: cmds:
              mapAttrsToList (name: cmd: {
                inherit
                  category
                  name
                  clusterName
                  cmd
                  ;
              }) cmds
            ) (clusterCfg.ops or { })
          )
        ) config.lab.out.allClusters
      );
    in
    mapAttrs (_: byCategory: groupBy (t: t.name) byCategory) (groupBy (t: t.category) tuples);

  mergeAcrossClusters =
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

      # A floe that declares its own `cluster` option keeps it: velero does,
      # on all seven of its commands.
      finalOptions = {
        cluster = clusterOption;
      }
      // mergedOptions;

      packages = builtins.listToAttrs (map (e: nameValuePair e.clusterName e.cmd.package) entries);
    in
    {
      inherit (first) description args;
      options = finalOptions;
      inherit packages isSingleCluster;
    };

  mergedClusterOps = mapAttrs (_: byName: mapAttrs mergeAcrossClusters byName) clusterEntries;

  userOps = mapAttrs (
    _: cmds:
    mapAttrs (_: cmd: {
      inherit (cmd) description args;
      options = cmd.options or { };
      packages = { };
      isSingleCluster = false;
      userCommand = true;
      inherit (cmd) package;
      cluster = cmd.cluster or null;
    }) cmds
  ) cfg.commands;

  # Per category, so a lab-scope command only displaces a cluster-scope one it
  # deliberately shares a category and a name with.
  allCommands = lib.zipAttrsWith (_: sets: lib.foldl' (a: b: a // b) { } sets) [
    mergedClusterOps
    userOps
  ];

  commandsByCategory = mapAttrs (
    _: cmds:
    mapAttrsToList (name: cmd: {
      inherit name;
      inherit (cmd) description;
      cmd = cmd;
    }) cmds
  ) allCommands;

  labName = config.lab.name;

  toolScript = opsToolScript {
    inherit labName commandsByCategory;
    inherit (config.lab.out) runtimeContexts;
  };
in
{
  options.lab.ops = {
    commands = mkOption {
      type = types.attrsOf (types.attrsOf opsCommandType);
      default = { };
      description = ''
        Lab-global operational commands, keyed by category then by name, so
        `lab.ops.commands.trust.setup` is run as `<lab>-ops trust setup`.

        Components contribute cluster-scoped commands through the
        cluster-level `ops.<category>.<name>` option. The same category and
        name from several clusters are merged, with enum option values
        unioned and a `--cluster` flag added to pick between them. A command
        here displaces a cluster's of the same category and name.
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

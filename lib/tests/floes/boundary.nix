{ lib, ... }:

let
  floesDir = ../../../modules/lab/cluster/floes;

  inherit (builtins)
    readDir
    readFile
    attrNames
    split
    isList
    ;
  inherit (lib) filterAttrs concatMap filter;

  floeNames = attrNames (filterAttrs (_: t: t == "directory") (readDir floesDir));

  nixFilesIn =
    floe:
    let
      dir = floesDir + "/${floe}";
      entries = filterAttrs (n: t: t == "regular" && lib.hasSuffix ".nix" n) (readDir dir);
    in
    map (n: {
      inherit floe;
      name = n;
      path = dir + "/${n}";
    }) (attrNames entries);

  matchesIn = content: filter isList (split "config\\.floes\\.([a-zA-Z-]+)\\.([a-zA-Z_]+)" content);

  violationsFor =
    file:
    let
      hits = matchesIn (readFile file.path);
      bad = filter (m: (builtins.elemAt m 0) != file.floe && (builtins.elemAt m 1) != "exports") hits;
    in
    map (
      m:
      "${file.floe}/${file.name} reads `config.floes.${builtins.elemAt m 0}.${builtins.elemAt m 1}`: "
      + "that is ${builtins.elemAt m 0}'s internal state, not its interface. "
      + "Read `peers.${builtins.elemAt m 0}.<field>` instead, and if the field you need is not "
      + "exported, add it to ${builtins.elemAt m 0}'s `exports`; publishing is that floe's call."
    ) bad;

  violations = concatMap violationsFor (concatMap nixFilesIn floeNames);
in
violations

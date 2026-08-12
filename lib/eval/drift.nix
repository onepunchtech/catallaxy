{ lib }:

let
  inherit (lib)
    concatStringsSep
    filter
    foldl'
    unique
    ;

  splitPath =
    path:
    let
      chars = lib.stringToCharacters path;
      step =
        acc: c:
        if c == "\"" then
          acc // { inQuote = !acc.inQuote; }
        else if c == "." && !acc.inQuote then
          acc
          // {
            done = acc.done ++ [ acc.cur ];
            cur = "";
          }
        else
          acc // { cur = acc.cur + c; };
      final = foldl' step {
        done = [ ];
        cur = "";
        inQuote = false;
      } chars;
    in
    filter (s: s != "") (final.done ++ [ final.cur ]);

  escapeSegment = seg: builtins.replaceStrings [ "~" "/" ] [ "~0" "~1" ] seg;

  escapePointer = path: "/" + concatStringsSep "/" (map escapeSegment (splitPath path));

  customizationKey =
    group: kind:
    if group == "" then
      throw "drift: core-group kinds cannot be declared at cluster scope (kind '${kind}'); declare on the bundle instead"
    else
      "${group}_${kind}";

  renderBody =
    { managers, pointers }:
    let
      managerBlock =
        if managers == [ ] then [ ] else [ "managedFieldsManagers:" ] ++ map (m: "- ${m}") managers;
      pointerBlock = if pointers == [ ] then [ ] else [ "jsonPointers:" ] ++ map (p: "- ${p}") pointers;
    in
    concatStringsSep "\n" (managerBlock ++ pointerBlock) + "\n";

in
{
  inherit escapePointer customizationKey;

  toArgocdResourceCustomizations =
    {
      entries,
      aggregateManagers ? [ ],
    }:
    let

      addEntry =
        acc: entry:
        foldl' (
          inner: kind:
          let
            key = customizationKey entry.group kind;
            prev =
              inner.${key} or {
                managers = [ ];
                pointers = [ ];
              };
          in
          inner
          // {
            ${key} = {
              managers = prev.managers ++ entry.managedBy;
              pointers = prev.pointers ++ map escapePointer entry.fields;
            };
          }
        ) acc entry.kinds;

      merged = foldl' addEntry { } entries;

      bodies = lib.mapAttrs (
        _: v:
        renderBody {

          managers = lib.sort (a: b: a < b) (unique (v.managers ++ aggregateManagers));
          pointers = lib.sort (a: b: a < b) (unique v.pointers);
        }
      ) merged;
    in
    lib.mapAttrs' (k: v: lib.nameValuePair "resource.customizations.ignoreDifferences.${k}" v) (
      lib.filterAttrs (_: v: v != "\n") bodies
    );

  toArgocdIgnoreDifferences =
    entries:
    lib.concatMap (
      entry:
      map (
        kind:
        {
          inherit (entry) group;
          inherit kind;
        }
        // lib.optionalAttrs (entry.managedBy != [ ]) {
          managedFieldsManagers = entry.managedBy;
        }
        // lib.optionalAttrs (entry.fields != [ ]) {
          jsonPointers = map escapePointer entry.fields;
        }
        // lib.optionalAttrs (entry.name != null) { inherit (entry) name; }
        // lib.optionalAttrs (entry.namespace != null) { inherit (entry) namespace; }
      ) entry.kinds
    ) (filter (e: e.managedBy != [ ] || e.fields != [ ]) entries);
}

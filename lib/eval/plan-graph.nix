{ lib }:

let
  inherit (lib)
    attrNames
    concatMap
    concatStringsSep
    elemAt
    filterAttrs
    foldl'
    hasPrefix
    length
    removePrefix
    splitString
    ;

  shared = import ./graph.nix { inherit lib; };

  inherit (shared) parseAnchor buildProvidesIdx;

  matchAnchor =
    steps: providesIdx: body:
    if hasPrefix "kind:" body then
      let
        parts = splitString ":" body;
        kind = elemAt parts 1;

        scope = if length parts > 2 then elemAt parts 2 else null;
        matching = filterAttrs (
          _: s: (s.kind or null) == kind && (scope == null || (s.cluster or null) == scope)
        ) steps;
      in
      attrNames matching
    else if hasPrefix "provides:" body then
      providesIdx.${removePrefix "provides:" body} or [ ]
    else
      providesIdx.${body} or [ ];

  originOf =
    steps: stepName:
    let
      declared = steps.${stepName}.origin or null;
    in
    if declared == null then "lab.steps.${stepName}" else declared;

  resolveAnchorList = shared.resolveAnchorList {
    inherit matchAnchor;
    onUnmatched =
      {
        nodes,
        node,
        field,
        body,
        ...
      }:
      throw ''
        ${originOf nodes node}: ${field} names '${body}', which no step provides.

        A bare name is looked up among the tokens steps publish. `kind:<kind>`
        and `kind:<kind>:<cluster>` address steps by what they are, which is
        the only way to name a step: a step's own key is private to whichever
        module emitted it, and a cluster's steps are renamed to
        `<cluster>-<name>` before they get here.

        Supply it with `provides = [ "${body}" ]` on the step that does, or
        write it as 'optional:${body}' if it is allowed to match nothing.
      '';
  };

  conflictErrors = shared.conflictErrors {
    inherit matchAnchor;
    onConflict =
      {
        nodes,
        name,
        conflicted,
        others,
      }:
      ''
        ${originOf nodes name} conflicts with '${conflicted}', which ${
          concatStringsSep " and " (map (n: "${originOf nodes n}") others)
        } also provides.

        Two steps making the same thing true both run, in whichever order
        the sort happens to pick, and the second undoes or duplicates the
        first. Drop one, or have the second wait on the token instead of
        publishing it.
      '';
  };

  buildEdges =
    steps:
    let
      providesIdx = buildProvidesIdx steps;
      names = attrNames steps;

      directPreds =
        name:
        let
          s = steps.${name};
        in
        (resolveAnchorList steps providesIdx name "after" (s.after or [ ]))
        ++ (resolveAnchorList steps providesIdx name "requires" (s.requires or [ ]));

      invertedBefore =
        let
          pairs = concatMap (
            preName:
            let
              targets = resolveAnchorList steps providesIdx preName "before" (steps.${preName}.before or [ ]);
            in
            map (postName: {
              inherit preName postName;
            }) targets
          ) names;
        in
        foldl' (
          acc: p:
          acc
          // {
            ${p.postName} = (acc.${p.postName} or [ ]) ++ [ p.preName ];
          }
        ) { } pairs;
    in
    shared.buildEdges {
      nodes = steps;
      directPreds = name: (directPreds name) ++ (invertedBefore.${name} or [ ]);
    };

  kahnSort = shared.kahnSort {
    onCycle =
      { remaining, ... }:
      throw ''
        lab.steps: dependency cycle among: ${builtins.toJSON remaining}.
        At least one pair of steps mutually require each other via
        after/before/requires edges. Inspect the anchor lists on the
        named steps and break the cycle.
      '';
  };

  topoSort =
    { steps }:
    let
      edges = buildEdges steps;
      order = kahnSort edges;
    in
    map (name: steps.${name} // { inherit name; }) order;

in
{
  inherit
    parseAnchor
    buildProvidesIdx
    matchAnchor
    buildEdges
    conflictErrors
    kahnSort
    topoSort
    ;
}

{ lib }:

let
  inherit (lib)
    attrNames
    concatLists
    concatMap
    filter
    filterAttrs
    foldl'
    genAttrs
    hasAttr
    hasPrefix
    removePrefix
    unique
    ;

  parseAnchor =
    anchor:
    if hasPrefix "optional:" anchor then
      {
        hard = false;
        body = removePrefix "optional:" anchor;
      }
    else
      {
        hard = true;
        body = anchor;
      };

  buildProvidesIdx =
    bundles:
    foldl' (
      acc: name:
      foldl' (
        inner: tok:
        inner
        // {
          ${tok} = (inner.${tok} or [ ]) ++ [ name ];
        }
      ) acc (bundles.${name}.provides or [ ])
    ) { } (attrNames bundles);

  matchAnchor =
    bundles: providesIdx: body:
    if hasPrefix "kind:" body then
      let
        kind = removePrefix "kind:" body;
      in
      attrNames (filterAttrs (_: b: (b.kind or null) == kind) bundles)
    else if hasPrefix "floe:" body then
      let
        floe = removePrefix "floe:" body;
      in
      attrNames (filterAttrs (_: b: (b.floe or null) == floe) bundles)
    else if hasPrefix "provides:" body then
      providesIdx.${removePrefix "provides:" body} or [ ]
    else if hasPrefix "bundle:" body then
      let
        name = removePrefix "bundle:" body;
      in
      if hasAttr name bundles then [ name ] else [ ]
    else if hasAttr body bundles then
      [ body ]
    else
      [ ];

  resolveAnchorList =
    bundles: providesIdx: bundleName: field: anchors:
    concatMap (
      a:
      let
        p = parseAnchor a;
        matches = matchAnchor bundles providesIdx p.body;
      in
      if matches == [ ] && p.hard then
        throw ''
          bundle '${bundleName}': ${field} anchor '${a}' matched no bundle.
          Anchor grammar: <name> | bundle:<name> | kind:<k8s-kind> | floe:<floe> | provides:<token>.
          Prefix with 'optional:' to silence this error when the anchor is
          allowed to match nothing.
        ''
      else
        matches
    ) anchors;

  resolveRequires =
    providesIdx: bundleName: requires:
    concatMap (
      req:
      let
        providers = providesIdx.${req} or [ ];
      in
      if providers == [ ] then
        throw ''
          bundle '${bundleName}': requires '${req}' but no bundle provides it.
          Declare a bundle with `provides = [ "${req}" ]` or drop the require.
        ''
      else
        providers
    ) requires;

  buildEdges =
    bundles:
    let
      providesIdx = buildProvidesIdx bundles;
      names = attrNames bundles;

      directPreds =
        name:
        let
          b = bundles.${name};
        in
        (resolveAnchorList bundles providesIdx name "after" (b.after or [ ]))
        ++ (resolveRequires providesIdx name (b.requires or [ ]));

      predsOf = name: filter (n: n != name) (unique (directPreds name));
    in
    genAttrs names predsOf;

  kahnWaves =
    edges:
    let
      names = attrNames edges;

      successors =
        let
          allPairs = concatMap (post: map (pre: { inherit pre post; }) edges.${post}) names;
        in
        foldl' (
          acc: p:
          acc
          // {
            ${p.pre} = (acc.${p.pre} or [ ]) ++ [ p.post ];
          }
        ) (genAttrs names (_: [ ])) allPairs;

      initialInDeg = genAttrs names (n: builtins.length edges.${n});

      loop =
        state:
        let
          zero = filter (n: state.inDeg.${n} == 0) state.remaining;
          zeroSorted = lib.sort (a: b: a < b) zero;
        in
        if zeroSorted == [ ] then
          if state.remaining == [ ] then
            state.waves
          else
            throw ''
              manifest bundles: dependency cycle among: ${builtins.toJSON state.remaining}.
              At least one pair of bundles mutually require each other via
              after/requires edges. Inspect the anchor lists on the named
              bundles and break the cycle.
            ''
        else
          let
            newRemaining = filter (n: !(builtins.elem n zeroSorted)) state.remaining;

            newInDeg = foldl' (
              acc: pick:
              foldl' (
                acc': succ:
                acc'
                // {
                  ${succ} = acc'.${succ} - 1;
                }
              ) acc (successors.${pick} or [ ])
            ) state.inDeg zeroSorted;
          in
          loop {
            remaining = newRemaining;
            inDeg = newInDeg;
            waves = state.waves ++ [ zeroSorted ];
          };
    in
    loop {
      remaining = names;
      inDeg = initialInDeg;
      waves = [ ];
    };

  computeWaves =
    { bundles }:
    let
      edges = buildEdges bundles;
      waves = kahnWaves edges;
    in
    map (waveNames: map (name: bundles.${name} // { inherit name; }) waveNames) waves;

  topoSort =
    { bundles }:
    concatLists (computeWaves {
      inherit bundles;
    });

  closurePredecessors =
    { bundles, roots }:
    let
      edges = buildEdges bundles;
      walk =
        seen: name:
        if !(bundles ? ${name}) || builtins.elem name seen then
          seen
        else
          foldl' walk (seen ++ [ name ]) (edges.${name} or [ ]);
    in
    foldl' walk [ ] roots;

in
{
  inherit
    parseAnchor
    buildProvidesIdx
    matchAnchor
    buildEdges
    kahnWaves
    computeWaves
    topoSort
    closurePredecessors
    ;
}

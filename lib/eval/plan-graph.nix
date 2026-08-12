{ lib }:

let
  inherit (lib)
    attrNames
    concatMap
    elemAt
    filter
    filterAttrs
    foldl'
    genAttrs
    hasAttr
    hasPrefix
    length
    mapAttrsToList
    removePrefix
    splitString
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
    steps:
    foldl' (
      acc: name:
      foldl' (
        inner: tok:
        inner
        // {
          ${tok} = (inner.${tok} or [ ]) ++ [ name ];
        }
      ) acc (steps.${name}.provides or [ ])
    ) { } (attrNames steps);

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
      throw ''
        '${body}' is not an anchor. Anchor grammar:
          provides:<token>        every step publishing that token
          kind:<kind>             every step of that kind
          kind:<kind>:<cluster>   the same, narrowed to one cluster
        Prefix any of them with 'optional:' to allow matching nothing.

        A bare step name is not an anchor. A name is its emitter's private
        vocabulary and moves when the emitter changes; a published token is
        the interface. If the step you meant publishes no token, give it one
        and anchor on that.
      '';

  originOf =
    steps: stepName:
    let
      declared = steps.${stepName}.origin or null;
    in
    if declared == null then "lab.steps.${stepName}" else declared;

  resolveAnchorList =
    steps: providesIdx: stepName: field: anchors:
    concatMap (
      a:
      let
        p = parseAnchor a;
        matches = matchAnchor steps providesIdx p.body;
      in
      if matches == [ ] && p.hard then
        throw ''
          ${originOf steps stepName}: ${field} anchor '${a}' matched no step.
          Prefix with 'optional:' to silence this error when the anchor is
          allowed to match nothing.
        ''
      else
        matches
    ) anchors;

  resolveRequires =
    steps: providesIdx: stepName: requires:
    concatMap (
      req:
      let
        providers = providesIdx.${req} or [ ];
      in
      if providers == [ ] then
        throw ''
          ${originOf steps stepName}: requires '${req}' but no step provides it.
          Declare a step with `provides = [ "${req}" ]` or drop the require.
        ''
      else
        providers
    ) requires;

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
        ++ (resolveRequires steps providesIdx name (s.requires or [ ]));

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

      predsOf =
        name: filter (n: n != name) (unique ((directPreds name) ++ (invertedBefore.${name} or [ ])));
    in
    genAttrs names predsOf;

  kahnSort =
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

      initialInDeg = genAttrs names (n: length edges.${n});

      loop =
        state:
        let
          zero = filter (n: state.inDeg.${n} == 0) state.remaining;
          zeroSorted = lib.sort (a: b: a < b) zero;
        in
        if zeroSorted == [ ] then
          if state.remaining == [ ] then
            state.result
          else
            throw ''
              lab.steps: dependency cycle among: ${builtins.toJSON state.remaining}.
              At least one pair of steps mutually require each other via
              after/before/requires edges. Inspect the anchor lists on the
              named steps and break the cycle.
            ''
        else
          let
            pick = builtins.head zeroSorted;
            newRemaining = filter (n: n != pick) state.remaining;
            newInDeg = foldl' (
              acc: succ:
              acc
              // {
                ${succ} = acc.${succ} - 1;
              }
            ) state.inDeg (successors.${pick} or [ ]);
          in
          loop {
            remaining = newRemaining;
            inDeg = newInDeg;
            result = state.result ++ [ pick ];
          };
    in
    loop {
      remaining = names;
      inDeg = initialInDeg;
      result = [ ];
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
    kahnSort
    topoSort
    ;
}

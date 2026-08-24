{ lib }:

let
  inherit (lib)
    attrNames
    concatMap
    filter
    foldl'
    genAttrs
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
    nodes:
    foldl' (
      acc: name:
      foldl' (
        inner: tok:
        inner
        // {
          ${tok} = (inner.${tok} or [ ]) ++ [ name ];
        }
      ) acc (nodes.${name}.provides or [ ])
    ) { } (attrNames nodes);

  # `requires` and `after` differ in strength, not in what a name means, so
  # both resolve here. Deciding it in one place is what stops the two verbs
  # drifting into two namespaces again.
  resolveAnchorList =
    {
      matchAnchor,
      onUnmatched,
    }:
    nodes: providesIdx: nodeName: field: anchors:
    concatMap (
      a:
      let
        p = parseAnchor a;
        matches = matchAnchor nodes providesIdx p.body;
      in
      if matches == [ ] && p.hard then
        onUnmatched {
          inherit nodes field;
          node = nodeName;
          anchor = a;
          inherit (p) body;
        }
      else
        matches
    ) anchors;

  # A conflict is exclusivity stated the way rpm states it: a provider of an
  # exclusive name also conflicts with that name, so two providers collide and
  # one provider does not collide with itself.
  conflictErrors =
    { matchAnchor, onConflict }:
    nodes:
    let
      providesIdx = buildProvidesIdx nodes;
    in
    concatMap (
      name:
      concatMap (
        conflicted:
        let
          # When both ends declare the conflict the pair would be reported
          # twice, so the lexically first speaks for it. Suppressing on order
          # alone would lose the pair entirely when only one end declares it
          # and that end sorts later, so the other end has to have said it too.
          alsoConflicts = n: builtins.elem conflicted (nodes.${n}.conflicts or [ ]);
          others = filter (n: n != name && !(alsoConflicts n && n < name)) (
            matchAnchor nodes providesIdx conflicted
          );
        in
        if others == [ ] then
          [ ]
        else
          [
            (onConflict {
              inherit
                nodes
                name
                conflicted
                others
                ;
            })
          ]
      ) (nodes.${name}.conflicts or [ ])
    ) (attrNames nodes);

  buildEdges =
    { nodes, directPreds }:
    genAttrs (attrNames nodes) (name: filter (n: n != name) (unique (directPreds name)));

  successorsOf =
    edges:
    let
      names = attrNames edges;
      allPairs = concatMap (post: map (pre: { inherit pre post; }) edges.${post}) names;
    in
    foldl' (
      acc: p:
      acc
      // {
        ${p.pre} = (acc.${p.pre} or [ ]) ++ [ p.post ];
      }
    ) (genAttrs names (_: [ ])) allPairs;

  # One ready node at a time, recomputing after each. Distinct from
  # `kahnWaves`, which takes every ready node together: with wave 0 = {a, z}
  # where picking `a` frees `b`, this gives a, b, z and flattened waves give
  # a, z, b. Both are valid topological orders and the callers depend on
  # theirs, so neither is derived from the other.
  kahnSort =
    { onCycle }:
    edges:
    let
      names = attrNames edges;
      successors = successorsOf edges;

      loop =
        state:
        let
          zero = lib.sort (a: b: a < b) (filter (n: state.inDeg.${n} == 0) state.remaining);
        in
        if zero == [ ] then
          if state.remaining == [ ] then
            state.result
          else
            onCycle {
              inherit edges;
              inherit (state) remaining;
            }
        else
          let
            pick = builtins.head zero;
            newInDeg = foldl' (
              acc: succ:
              acc
              // {
                ${succ} = acc.${succ} - 1;
              }
            ) state.inDeg (successors.${pick} or [ ]);
          in
          loop {
            remaining = filter (n: n != pick) state.remaining;
            inDeg = newInDeg;
            result = state.result ++ [ pick ];
          };
    in
    loop {
      remaining = names;
      inDeg = genAttrs names (n: builtins.length edges.${n});
      result = [ ];
    };

  kahnWaves =
    { onCycle }:
    edges:
    let
      names = attrNames edges;
      successors = successorsOf edges;

      loop =
        state:
        let
          zero = lib.sort (a: b: a < b) (filter (n: state.inDeg.${n} == 0) state.remaining);
        in
        if zero == [ ] then
          if state.remaining == [ ] then
            state.waves
          else
            onCycle {
              inherit edges;
              inherit (state) remaining;
            }
        else
          let
            newInDeg = foldl' (
              acc: pick:
              foldl' (
                acc': succ:
                acc'
                // {
                  ${succ} = acc'.${succ} - 1;
                }
              ) acc (successors.${pick} or [ ])
            ) state.inDeg zero;
          in
          loop {
            remaining = filter (n: !(builtins.elem n zero)) state.remaining;
            inDeg = newInDeg;
            waves = state.waves ++ [ zero ];
          };
    in
    loop {
      remaining = names;
      inDeg = genAttrs names (n: builtins.length edges.${n});
      waves = [ ];
    };

  closureFrom =
    { edges, roots }:
    let
      walk =
        seen: name:
        if !(edges ? ${name}) || builtins.elem name seen then
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
    resolveAnchorList
    conflictErrors
    buildEdges
    kahnSort
    kahnWaves
    closureFrom
    ;
}

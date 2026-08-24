{ lib }:

let
  inherit (lib)
    attrNames
    concatLists
    concatStringsSep
    filter
    filterAttrs
    hasAttr
    hasPrefix
    removePrefix
    ;

  shared = import ./graph.nix { inherit lib; };

  inherit (shared) parseAnchor buildProvidesIdx closureFrom;

  # `kind:` is deliberately absent: it is an ordinary provided name now,
  # supplied by whoever installs the CRD, so it falls through to the index
  # below. It used to mean "any bundle holding a resource of this kind",
  # which reads the same and answers the opposite question - every emitter
  # of a Certificate rather than the one thing that admits one.
  matchAnchor =
    bundles: providesIdx: body:
    if hasPrefix "floe:" body then
      let
        floe = removePrefix "floe:" body;
      in
      attrNames (filterAttrs (_: b: (b.declaredBy or null) == floe) bundles)
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
      providesIdx.${body} or [ ];

  isStepAnchor = a: hasPrefix "step:" (parseAnchor a).body;

  # A `step:` name belongs to the lab's plan, not to this cluster, so there
  # is no bundle here for it to order against and no index that could answer
  # it. It is dropped from the edges and collected instead, and the lab
  # checks that whatever publishes it runs before the manifests are applied.
  stepAnchors =
    bundles:
    lib.concatMap (
      name:
      lib.concatMap
        (
          field:
          map (a: {
            bundle = name;
            inherit field;
            token = removePrefix "step:" (parseAnchor a).body;
            inherit (parseAnchor a) hard;
          }) (filter isStepAnchor (bundles.${name}.${field} or [ ]))
        )
        [
          "after"
          "requires"
        ]
    ) (attrNames bundles);

  resolveAnchorList =
    bundles: providesIdx: bundleName: field: anchors:
    baseResolveAnchorList bundles providesIdx bundleName field (filter (a: !(isStepAnchor a)) anchors);

  baseResolveAnchorList = shared.resolveAnchorList {
    inherit matchAnchor;
    onUnmatched =
      {
        node,
        field,
        body,
        ...
      }:
      throw ''
        bundle '${node}': ${field} names '${body}', which nothing on
        this cluster provides.

        A name resolves against a bundle of that name, then against
        everything any bundle lists in `provides`. Derived names carry a
        prefix (bundle:, floe:, kind:, namespace:); hand-written ones are
        bare, by convention <scope>/<subject>/<state>. `step:<token>`
        reaches a lab plan step instead, for something that has to happen
        before the manifests are applied at all.

        Supply it with `provides = [ "${body}" ]` on the bundle that does,
        or write it as 'optional:${body}' if it is allowed to match
        nothing.
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
      let
        remedies = filter (r: r != null) (map (n: nodes.${n}.disableWith or null) ([ name ] ++ others));
      in
      ''
        bundle '${name}' conflicts with '${conflicted}', which ${
          concatStringsSep " and " (map (n: "'${n}'") others)
        } also provides.

        Two providers of one name do not merge: they claim the same
        objects and the same traffic, and which one wins depends on the
        order things reconcile in, so the cluster comes up and then
        disagrees with itself. Turn one of them off:
        ${concatStringsSep "\n" (map (r: "  " + r) remedies)}
      '';
  };

  buildEdges =
    bundles:
    let
      providesIdx = buildProvidesIdx bundles;
      conflicts = conflictErrors bundles;

      directPreds =
        name:
        let
          b = bundles.${name};
        in
        (resolveAnchorList bundles providesIdx name "after" (b.after or [ ]))
        ++ (resolveAnchorList bundles providesIdx name "requires" (b.requires or [ ]));
    in
    if conflicts != [ ] then
      throw (concatStringsSep "\n" conflicts)
    else
      shared.buildEdges {
        nodes = bundles;
        inherit directPreds;
      };

  kahnWaves = shared.kahnWaves {
    onCycle =
      { edges, remaining }:
      throw ''
        manifest bundles: dependency cycle.

        These are all still waiting, each on the ones named after it.
        Only edges inside the cycle are shown, so every line here is
        part of the knot rather than of the tree hanging off it:

        ${concatStringsSep "\n" (
          map (
            n: "  ${n} <- ${concatStringsSep ", " (filter (p: builtins.elem p remaining) edges.${n})}"
          ) remaining
        )}

        Break it by making one of those edges optional, or by moving
        what it depends on into a bundle of its own.
      '';
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
      unknown = builtins.filter (name: !(bundles ? ${name})) roots;
      checkedRoots =
        if unknown == [ ] then
          roots
        else
          throw ''
            `cluster.provisioning.rootBundles` names ${
              concatStringsSep ", " (map (n: "'${n}'") unknown)
            }, which ${
              if builtins.length unknown == 1 then "is not a bundle" else "are not bundles"
            } on this cluster. It has: ${concatStringsSep ", " (attrNames bundles)}.

            The stage1 set is the dependency closure of these roots, so a name
            that matches nothing quietly drops everything it should have pulled
            in. The bootstrap then comes up missing the CRDs the cluster needs
            and fails at apply rather than here.
          '';
    in
    closureFrom {
      edges = buildEdges bundles;
      roots = checkedRoots;
    };

in
{
  inherit
    parseAnchor
    buildProvidesIdx
    matchAnchor
    stepAnchors
    buildEdges
    conflictErrors
    kahnWaves
    computeWaves
    topoSort
    closurePredecessors
    ;
}

{ lib }:

let
  refs = import ./ref.nix { inherit lib; };

  refsWithPath =
    prefix: value:
    if refs.isRef value then
      [
        {
          path = prefix;
          ref = value;
        }
      ]
    else if builtins.isAttrs value then
      lib.concatLists (lib.mapAttrsToList (k: v: refsWithPath "${prefix}.${k}" v) value)
    else if builtins.isList value then
      lib.concatLists (lib.imap0 (i: v: refsWithPath "${prefix}[${toString i}]" v) value)
    else
      [ ];
  # Only the parts of a bundle that are not schema-typed. A reference in a
  # typed field is already refused by the Kubernetes type it lands in, with a
  # message naming the option path. These are the fields that would accept it
  # and carry it all the way into a chart or a patch as a literal string.
  untypedIn = bundle: {
    resources = bundle.resources or { };
    helmValues = lib.mapAttrs (_: chart: chart.values or { }) (bundle.helmCharts or { });
    patches = bundle.patches or [ ];
    patchesJson6902 = bundle.patchesJson6902 or [ ];
  };
in
{
  inherit refsWithPath;

  referenceErrors =
    resources:
    let
      found = lib.concatLists (
        lib.mapAttrsToList (
          name: resource:
          map (r: {
            inherit name;
            inherit (r) path ref;
          }) (refsWithPath "infra.resources.${name}.inputs" resource.inputs)
        ) resources
      );

      errorFor =
        found:
        let
          target = resources.${found.ref.resource} or null;
          source = resources.${found.name};
        in
        if target == null then
          ''
            ${found.path} references '${refs.show found.ref}', and no resource
            named '${found.ref.resource}' is declared.

            A reference resolves through the target's own type, so there is
            nothing to render it as. The resources this lab declares are:
            ${lib.concatStringsSep ", " (lib.attrNames resources)}.
          ''
        else if !(builtins.elem found.ref.output target.outputs) then
          ''
            ${found.path} references '${refs.show found.ref}', which
            '${found.ref.resource}' does not declare as an output. It declares:
            ${if target.outputs == [ ] then "nothing" else lib.concatStringsSep ", " target.outputs}.

            Outputs are declared rather than inferred, so that a reference to
            one that does not exist is refused here instead of by the provider
            at apply, after everything before it in the plan has already run.

            Add it to `outputs` on '${found.ref.resource}' if the provider
            really does expose it.
          ''
        else
          null;
    in
    lib.filter (m: m != null) (map errorFor found);

  # A reference points backwards in time or not at all. Referencing something
  # in a later phase asks for a value that does not exist yet when the earlier
  # stack applies, and the ordering the phases imply is the opposite of the
  # one the reference needs.
  phaseOrderErrors =
    { resources, order }:
    let
      indexOf = phase: lib.lists.findFirstIndex (p: p == phase) 0 order;
    in
    lib.concatLists (
      lib.mapAttrsToList (
        name: resource:
        lib.concatMap (
          found:
          let
            target = resources.${found.ref.resource} or null;
          in
          lib.optional (target != null && indexOf target.phase > indexOf resource.phase) ''
            ${found.path} references '${refs.show found.ref}', which is in
            phase '${target.phase}' while '${name}' is in phase
            '${resource.phase}'.

            A phase is a point in the lab's lifecycle, and '${resource.phase}'
            comes first. The value being referenced does not exist yet when
            this applies, and ordering the two the way the reference needs
            would put the phases in the wrong order.

            Move '${name}' to '${target.phase}' if it can wait, or move
            '${found.ref.resource}' earlier if it does not need what its
            phase waits for.
          ''
        ) (refsWithPath "infra.resources.${name}.inputs" resource.inputs)
      ) resources
    );

  identifierErrors =
    { resources, stacks }:
    let
      valid = name: builtins.match "[A-Za-z_][A-Za-z0-9_-]*" name != null;
    in
    map (name: ''
      infra resource '${name}' is not a valid terraform name.

      A name has to start with a letter or an underscore and hold only
      letters, digits, underscores and dashes. This one becomes a parse error
      in a file nobody wrote by hand, which is a bad place to meet it.

      A cluster's resources are prefixed with the cluster's name, so an
      unusual cluster name can be what did it.
    '') (lib.filter (name: !(valid name)) (lib.attrNames resources))
    ++ map (name: ''
      infra stack '${name}' is not a valid terraform name.

      Stack names reach the rendered file as remote-state data source names,
      so they have the same rule: a letter or underscore, then letters,
      digits, underscores and dashes.

      A stack is named by routing, so a provider name or a
      `routing.byProvider` value is what to change.
    '') (lib.filter (name: !(valid name)) stacks);

  # Two stacks writing one state file is the worst thing this can do: each
  # apply sees the other's resources as things to destroy. Nothing about a
  # backend is checked beyond this, because backends differ, but two of them
  # being identical means the same file whatever the backend is.
  backendCollisionErrors =
    assembled:
    let
      byBackend = lib.foldl' (
        acc: name:
        let
          key = builtins.toJSON assembled.${name}.backend;
        in
        acc // { ${key} = (acc.${key} or [ ]) ++ [ name ]; }
      ) { } (lib.attrNames assembled);

      shared = lib.filterAttrs (_: names: lib.length names > 1) byBackend;
    in
    lib.mapAttrsToList (backend: names: ''
      stacks ${lib.concatStringsSep " and " (map (n: "'${n}'") names)} resolve to
      the same state:

        ${backend}

      A stack is a unit of state, so two sharing one file means each apply
      sees the other's resources as things it did not declare and should
      destroy.

      `lab.infra.backend` replaces the literal `<stack>` with each stack's
      name, which is how one declaration gives each its own key. This one
      contains no `<stack>`, or the field that would differ is not part of
      the backend.
    '') shared;

  stackCycleErrors =
    { routed, stacks }:
    let
      edgesOf =
        stackName:
        lib.unique (
          lib.concatLists (
            lib.mapAttrsToList (
              _: r:
              map (found: routed.${found.ref.resource}.stack) (
                lib.filter (found: routed ? ${found.ref.resource}) (refsWithPath "" r.inputs)
              )
            ) (lib.filterAttrs (_: r: r.stack == stackName) routed)
          )
        );

      reaches =
        seen: stackName:
        let
          next = lib.filter (s: s != stackName) (edgesOf stackName);
          fresh = lib.filter (s: !(builtins.elem s seen)) next;
        in
        next ++ lib.concatMap (reaches (seen ++ fresh)) fresh;

      cyclic = lib.filter (s: builtins.elem s (reaches [ s ] s)) stacks;
    in
    map (s: ''
      stack '${s}' reaches itself through what it references: ${
        lib.concatStringsSep " -> " ([ s ] ++ edgesOf s)
      }.

      A stack reading another's output has to apply after it, and the order
      is derived from the references rather than declared. Two stacks reading
      each other cannot both go first.

      Put the resources that reference each other in one stack, where the
      tool orders them itself, or break the loop.
    '') cyclic;

  publishErrors =
    { resources, stores }:
    lib.concatLists (
      lib.mapAttrsToList (
        name: resource:
        lib.concatLists (
          lib.mapAttrsToList (
            output: target:
            let
              store = stores.${target.store} or null;
            in
            if store == null then
              [
                ''
                  infra.resources.${name} publishes '${output}' to store
                  '${target.store}', which this lab does not declare. It
                  declares: ${if stores == { } then "none" else lib.concatStringsSep ", " (lib.attrNames stores)}.

                  Declare it as `lab.secrets.stores.${target.store}`.
                ''
              ]
            else if store.direction != "runtime" then
              [
                ''
                  infra.resources.${name} publishes '${output}' to store
                  '${target.store}', which is an `authored` store.

                  An authored store holds values you wrote, and for the `sops`
                  backend it is a file committed to your repository. An apply
                  produces values nobody wrote, so putting them there would
                  mean committing runtime state to git.

                  A runtime store is one nothing authors: the `vault` and
                  `external` backends. Point this at one of those, and the
                  cluster that needs the value reads it with
                  `secrets.subscribe`.
                ''
              ]
            else if !(builtins.elem output resource.outputs) then
              [
                ''
                  infra.resources.${name} publishes '${output}', which it does
                  not declare as an output. It declares: ${
                    if resource.outputs == [ ] then "nothing" else lib.concatStringsSep ", " resource.outputs
                  }.

                  Only a declared output exists to publish, for the same
                  reason a reference can only name one.
                ''
              ]
            else
              [ ]
          ) resource.publish
        )
      ) resources
    );

  manifestRefErrors =
    bundles:
    lib.concatLists (
      lib.mapAttrsToList (
        bundleName: bundle:
        map (found: ''
          bundles.${bundleName}${found.path} is a reference to
          '${refs.show found.ref}', which cannot go in a Kubernetes resource.

          A reference renders as the backend's interpolation syntax, and
          nothing in a cluster resolves that: the manifest would carry a
          literal string.

          Route it instead. Put the output in a runtime store with `publish`
          on the resource, and read it on this cluster with
          `secrets.subscribe`, which is the channel that already carries a
          value one part of the lab mints to another.
        '') (refsWithPath "" (untypedIn bundle))
      ) bundles
    );
}

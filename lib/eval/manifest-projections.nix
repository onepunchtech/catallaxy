{ lib }:

rec {

  extractSecretRefs =
    v:
    if builtins.isAttrs v then
      (lib.optional ((v.secretKeyRef.name or null) != null) {
        name = v.secretKeyRef.name;
        namespace = v.secretKeyRef.namespace or null;
      })
      ++ (lib.optional ((v.secretRef.name or null) != null) {
        name = v.secretRef.name;
        namespace = v.secretRef.namespace or null;
      })
      ++ (lib.optional ((v.secretName or null) != null) {
        name = v.secretName;
        namespace = null;
      })
      ++ lib.concatMap extractSecretRefs (lib.attrValues v)
    else if builtins.isList v then
      lib.concatMap extractSecretRefs v
    else
      [ ];

  consumedProjections =
    {
      bundle,
      projectionSet,
    }:
    lib.unique (
      lib.concatLists (
        lib.mapAttrsToList (
          _: res:
          let
            resNs = res.metadata.namespace or null;
          in
          map (ref: ref.name) (
            lib.filter (
              ref:
              projectionSet ? ${ref.name}
              && (if ref.namespace != null then ref.namespace else resNs) == projectionSet.${ref.name}.namespace
            ) (extractSecretRefs res)
          )
        ) (bundle.resources or { })
      )
    );

  withProjectionRequires =
    {
      bundles,
      projectionSet,
    }:
    lib.mapAttrs (
      _: b:
      b
      // {
        requires =
          b.requires
          ++ map (n: "secret:${projectionSet.${n}.namespace}/${n}") (consumedProjections {
            bundle = b;
            inherit projectionSet;
          });
      }
    ) bundles;
}

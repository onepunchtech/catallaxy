{ lib }:

let
  inherit (lib)
    attrNames
    attrValues
    concatMap
    filter
    foldl'
    mapAttrs
    optional
    unique
    ;

  resKind = r: r.kind or "";
  resNs = r: r.metadata.namespace or null;
  resName = r: r.metadata.name or null;
  isNamespace = r: resKind r == "Namespace";
  isCRD = r: resKind r == "CustomResourceDefinition";
  isSecretStore =
    r:
    builtins.elem (resKind r) [
      "SecretStore"
      "ClusterSecretStore"
    ];
  isExternalSecret = r: resKind r == "ExternalSecret";

  buildNamespaceProviders =
    {
      bundles,
      namespaceAggregate ? null,
    }:
    let
      fromCreateNamespaces =
        if namespaceAggregate == null then
          { }
        else
          foldl' (
            acc: bundleName:
            foldl' (inner: ns: inner // { ${ns} = namespaceAggregate; }) acc (
              bundles.${bundleName}.createNamespaces or [ ]
            )
          ) { } (attrNames bundles);

      fromResources = foldl' (
        acc: bundleName:
        let
          resources = attrValues (bundles.${bundleName}.resources or { });
          namespaces = filter isNamespace resources;
        in
        foldl' (
          inner: r:
          let
            n = resName r;
          in
          if n != null then inner // { ${n} = bundleName; } else inner
        ) acc namespaces
      ) { } (attrNames bundles);
    in
    fromCreateNamespaces // fromResources;

  buildCrdProviders =
    bundles:
    foldl' (
      acc: bundleName:
      let
        resources = attrValues (bundles.${bundleName}.resources or { });
        crds = filter isCRD resources;
      in
      foldl' (
        inner: r:
        let
          k = r.spec.names.kind or null;
        in
        if k != null then inner // { ${k} = bundleName; } else inner
      ) acc crds
    ) { } (attrNames bundles);

  buildSecretStoreProviders =
    bundles:
    foldl' (
      acc: bundleName:
      let
        resources = attrValues (bundles.${bundleName}.resources or { });
        stores = filter isSecretStore resources;
      in
      foldl' (
        inner: r:
        let
          n = resName r;
        in
        if n != null then inner // { ${n} = bundleName; } else inner
      ) acc stores
    ) { } (attrNames bundles);

  autoEdgesFor =
    {
      namespaceProviders,
      crdProviders,
      secretStoreProviders,
    }:
    bundleName: bundle:
    let
      resources = attrValues (bundle.resources or { });

      consumedNamespaces =
        (filter (n: n != null) (map resNs resources))
        ++ (map (h: h.namespace or null) (attrValues (bundle.helmCharts or { })))
        ++ (bundle.createNamespaces or [ ]);
      nsEdges = concatMap (
        ns:
        if ns != null && (namespaceProviders.${ns} or null) != null then
          [ (namespaceProviders.${ns}) ]
        else
          [ ]
      ) consumedNamespaces;

      crdEdges = concatMap (
        r:
        let
          k = resKind r;
          providerBundle = crdProviders.${k} or null;
        in
        if !(isCRD r) && providerBundle != null then [ providerBundle ] else [ ]
      ) resources;

      esEdges = concatMap (
        r:
        if !(isExternalSecret r) then
          [ ]
        else
          let
            storeName = r.spec.secretStoreRef.name or null;
            providerBundle = if storeName != null then secretStoreProviders.${storeName} or null else null;
          in
          if providerBundle != null then [ providerBundle ] else [ ]
      ) resources;

      allProviders = nsEdges ++ crdEdges ++ esEdges;

    in
    map (n: "bundle:${n}") (unique (filter (n: n != bundleName) allProviders));

  deriveAutoEdges =
    {
      bundles,
      namespaceAggregate ? null,
    }:
    let
      indices = {
        namespaceProviders = buildNamespaceProviders { inherit bundles namespaceAggregate; };
        crdProviders = buildCrdProviders bundles;
        secretStoreProviders = buildSecretStoreProviders bundles;
      };
    in
    mapAttrs (
      name: bundle:
      bundle
      // {
        after = (bundle.after or [ ]) ++ (autoEdgesFor indices name bundle);
      }
    ) bundles;

in
{
  inherit
    deriveAutoEdges
    buildNamespaceProviders
    buildCrdProviders
    buildSecretStoreProviders
    ;
}

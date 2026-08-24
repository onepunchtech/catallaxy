{ lib }:

let
  inherit (lib)
    attrNames
    attrValues
    filter
    foldl'
    mapAttrs
    unique
    ;

  resKind = r: r.kind or "";

  # Group-qualified, because `kind` alone does not identify anything.
  # `Cluster` is CloudNativePG's, Cluster API's and Crossplane's; `Backup` is
  # velero's and CloudNativePG's. `specTypeFor` resolves on the same pair for
  # the same reason.
  groupOf =
    apiVersion:
    let
      parts = lib.splitString "/" apiVersion;
    in
    if builtins.length parts < 2 then "" else builtins.head parts;

  resRef = r: "${groupOf (r.apiVersion or "")}/${resKind r}";
  resNs = r: r.metadata.namespace or null;
  resName = r: r.metadata.name or null;
  isNamespace = r: resKind r == "Namespace";
  isCRD = r: resKind r == "CustomResourceDefinition";

  # kapp reads its own `Config` out of the manifest stream and never applies
  # it, so nothing installs the kind and waiting for one deadlocks. The
  # argocd renderer already strips these for the same reason.
  isApplierConfig = r: groupOf (r.apiVersion or "") == "kapp.k14s.io";
  isSecretStore =
    r:
    builtins.elem (resKind r) [
      "SecretStore"
      "ClusterSecretStore"
    ];
  isExternalSecret = r: resKind r == "ExternalSecret";

  resourcesOf = bundle: attrValues (bundle.resources or { });

  # One provider per name, not one per declarer. Several bundles list the same
  # namespace in `createNamespaces`, and if each of them provided it, any two
  # that also put something in it would wait on each other.
  indexBy =
    bundles: pick:
    foldl' (
      acc: bundleName:
      foldl' (inner: key: inner // { ${key} = bundleName; }) acc (pick bundles.${bundleName})
    ) { } (attrNames bundles);

  namespaceProviders =
    { bundles, namespaceAggregate }:
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

      # A bundle declaring the Namespace object itself outranks the aggregate:
      # it is the thing that actually carries the labels and the finalizers.
      fromResources = indexBy bundles (
        b: filter (n: n != null) (map resName (filter isNamespace (resourcesOf b)))
      );
    in
    fromCreateNamespaces // fromResources;

  secretStoreProviders =
    bundles:
    indexBy bundles (b: filter (n: n != null) (map resName (filter isSecretStore (resourcesOf b))));

  crdProviders =
    bundles:
    indexBy bundles (
      b: map (r: "${r.spec.group or ""}/${r.spec.names.kind or ""}") (filter isCRD (resourcesOf b))
    );

  namesProvidedBy =
    providers: bundleName: prefix:
    map (key: "${prefix}:${key}") (filter (key: providers.${key} == bundleName) (attrNames providers));

  # Ordering only. A namespace has to exist before something lands in it, and a
  # store before the ExternalSecret naming it, but neither has a readiness of
  # its own worth waiting on. `optional:` because a namespace nothing in the
  # lab creates is one the cluster already had.
  autoAfter =
    bundle:
    let
      resources = resourcesOf bundle;

      consumedNamespaces = unique (
        filter (n: n != null) (
          (map resNs resources)
          ++ (map (h: h.namespace or null) (attrValues (bundle.helmCharts or { })))
          ++ (bundle.createNamespaces or [ ])
        )
      );

      consumedStores = unique (
        filter (n: n != null) (
          map (r: r.spec.secretStoreRef.name or null) (filter isExternalSecret resources)
        )
      );
    in
    map (n: "optional:namespace:${n}") consumedNamespaces
    ++ map (n: "optional:secretstore:${n}") consumedStores;

  # A resource of a kind Kubernetes does not ship is only applyable once
  # something has installed the CRD and, where there is one, brought up the
  # admission webhook fronting it. That is a readiness edge rather than an
  # ordering one, and it is the edge eleven floes wrote by hand and four
  # forgot.
  autoRequires =
    coreKinds: bundle:
    let
      wanted = filter (r: !(coreKinds ? ${resKind r}) && !(isApplierConfig r)) (resourcesOf bundle);
    in
    unique (map (r: "kind:${resRef r}") wanted);

  deriveAutoEdges =
    {
      bundles,
      namespaceAggregate ? null,
      coreKinds ? { },
    }:
    let
      namespaces = namespaceProviders { inherit bundles namespaceAggregate; };
      stores = secretStoreProviders bundles;
      crds = crdProviders bundles;
    in
    mapAttrs (
      name: bundle:
      bundle
      // {
        provides = unique (
          (bundle.provides or [ ])
          ++ [ "bundle:${name}" ]
          ++ lib.optional (bundle.declaredBy != "cluster") "floe:${bundle.declaredBy}"
          ++ namesProvidedBy namespaces name "namespace"
          ++ namesProvidedBy stores name "secretstore"
          ++ namesProvidedBy crds name "kind"
        );
        after = unique ((bundle.after or [ ]) ++ (autoAfter bundle));
        requires = unique ((bundle.requires or [ ]) ++ (autoRequires coreKinds bundle));
      }
    ) bundles;

in
{
  inherit
    deriveAutoEdges
    namespaceProviders
    secretStoreProviders
    crdProviders
    autoAfter
    autoRequires
    ;
}

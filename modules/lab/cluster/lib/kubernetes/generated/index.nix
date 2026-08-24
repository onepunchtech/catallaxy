{ lib }:

let
  k8sVersions = {
    "1_29" = import ./k8s/1_29.nix { inherit lib; };
    "1_30" = import ./k8s/1_30.nix { inherit lib; };
    "1_31" = import ./k8s/1_31.nix { inherit lib; };
    "1_32" = import ./k8s/1_32.nix { inherit lib; };
  };

  constructors = import ./constructors.nix { inherit lib; };

  loadCrds =
    versioned:
    let
      k8sTypes = versioned // constructors;
    in
    {
      argocd = import ./crds/argocd.nix { inherit lib k8sTypes; };
      capi_operator = import ./crds/capi_operator.nix { inherit lib k8sTypes; };
      cert_manager = import ./crds/cert_manager.nix { inherit lib k8sTypes; };
      cilium = import ./crds/cilium.nix { inherit lib k8sTypes; };
      cnpg = import ./crds/cnpg.nix { inherit lib k8sTypes; };
      crossplane = import ./crds/crossplane.nix { inherit lib k8sTypes; };
      external_dns = import ./crds/external_dns.nix { inherit lib k8sTypes; };
      external_secrets = import ./crds/external_secrets.nix { inherit lib k8sTypes; };
      gateway_api = import ./crds/gateway_api.nix { inherit lib k8sTypes; };
      kaniop = import ./crds/kaniop.nix { inherit lib k8sTypes; };
      netbird_operator = import ./crds/netbird_operator.nix { inherit lib k8sTypes; };
      prometheus = import ./crds/prometheus.nix { inherit lib k8sTypes; };
      redis_operator = import ./crds/redis_operator.nix { inherit lib k8sTypes; };
      trust_manager = import ./crds/trust_manager.nix { inherit lib k8sTypes; };
      velero = import ./crds/velero.nix { inherit lib k8sTypes; };
    };

  reservedAttrs = [
    "version"
    "mkTypedSubmodule"
    "mkResource"
    "crds"
  ];

  forVersion =
    version:
    let
      safeVersion = builtins.replaceStrings [ "." ] [ "_" ] version;
      k8sTypes = k8sVersions.${safeVersion} or (throw "Unknown K8s version: ${version}");
    in
    k8sTypes
    // {
      crds = loadCrds k8sTypes;
    };

  flattenTypes =
    versionedTypes:
    let
      inherit (builtins)
        isAttrs
        attrNames
        foldl'
        elem
        ;
      inherit (lib) filterAttrs;
      groups = filterAttrs (n: v: isAttrs v && !(elem n reservedAttrs)) versionedTypes;
      flattenGroup =
        group:
        let
          apiVersions = builtins.sort (a: b: a < b) (attrNames group);
        in
        foldl' (acc: av: acc // group.${av}) { } apiVersions;
      k8sFlat = foldl' (acc: gn: acc // flattenGroup groups.${gn}) { } (attrNames groups);
      crdFlat =
        if versionedTypes ? crds then
          foldl' (acc: cn: acc // versionedTypes.crds.${cn}) { } (attrNames versionedTypes.crds)
        else
          { };
    in
    k8sFlat // crdFlat;

  typesByKind =
    versionedTypes:
    let
      inherit (builtins)
        isAttrs
        attrNames
        foldl'
        elem
        ;
      inherit (lib) filterAttrs;
      groups = filterAttrs (n: v: isAttrs v && !(elem n reservedAttrs)) versionedTypes;
      addKinds =
        acc: kinds: foldl' (a: k: a // { ${k} = (a.${k} or [ ]) ++ [ kinds.${k} ]; }) acc (attrNames kinds);
      addGroup = acc: group: foldl' (a: av: addKinds a group.${av}) acc (attrNames group);
      k8sByKind = foldl' (acc: gn: addGroup acc groups.${gn}) { } (attrNames groups);
    in
    if versionedTypes ? crds then
      foldl' (acc: cn: addKinds acc versionedTypes.crds.${cn}) k8sByKind (attrNames versionedTypes.crds)
    else
      k8sByKind;

  # Kinds the API server ships, as a set. Everything else needs something to
  # install its CRD first, which is what makes this the dividing line for a
  # derived `kind:` requirement. `crds` is excluded on purpose: a vendor CRD
  # being in the generated schemas says catallaxy can type-check it, not that
  # any cluster has it.
  coreKinds =
    versionedTypes:
    let
      inherit (builtins)
        isAttrs
        attrNames
        foldl'
        elem
        ;
      inherit (lib) filterAttrs;
      groups = filterAttrs (n: v: isAttrs v && !(elem n reservedAttrs)) versionedTypes;
      addGroup =
        acc: group:
        foldl' (a: av: a // lib.genAttrs (attrNames group.${av}) (_: true)) acc (attrNames group);
    in
    foldl' (acc: gn: addGroup acc groups.${gn}) { } (attrNames groups);

  apiVersionOfType = type: (type.getSubOptions [ ]).apiVersion.default or null;

  apiVersionsForKind = byKind: kind: map apiVersionOfType (byKind.${kind} or [ ]);

  resolveResourceType =
    byKind: apiVersion: kind:
    let
      matching = builtins.filter (t: apiVersionOfType t == apiVersion) (byKind.${kind} or [ ]);
    in
    if matching == [ ] then null else builtins.head matching;

in
{
  inherit
    k8sVersions
    loadCrds
    forVersion
    flattenTypes
    ;
  inherit
    typesByKind
    apiVersionsForKind
    resolveResourceType
    coreKinds
    ;

  default = forVersion "1.31";
}

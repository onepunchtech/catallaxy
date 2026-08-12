{ lib }:

let
  k8sVersions = {
    "1_29" = import ./k8s/1_29.nix { inherit lib; };
    "1_30" = import ./k8s/1_30.nix { inherit lib; };
    "1_31" = import ./k8s/1_31.nix { inherit lib; };
    "1_32" = import ./k8s/1_32.nix { inherit lib; };
  };

  loadCrds = k8sTypes: {
    argocd = import ./crds/argocd.nix { inherit lib k8sTypes; };
    capi_operator = import ./crds/capi_operator.nix { inherit lib k8sTypes; };
    cert_manager = import ./crds/cert_manager.nix { inherit lib k8sTypes; };
    cilium = import ./crds/cilium.nix { inherit lib k8sTypes; };
    cnpg = import ./crds/cnpg.nix { inherit lib k8sTypes; };
    crossplane = import ./crds/crossplane.nix { inherit lib k8sTypes; };
    external_dns = import ./crds/external_dns.nix { inherit lib k8sTypes; };
    external_secrets = import ./crds/external_secrets.nix { inherit lib k8sTypes; };
    kaniop = import ./crds/kaniop.nix { inherit lib k8sTypes; };
    prometheus = import ./crds/prometheus.nix { inherit lib k8sTypes; };
    redis_operator = import ./crds/redis_operator.nix { inherit lib k8sTypes; };
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

in
{
  inherit
    k8sVersions
    loadCrds
    forVersion
    flattenTypes
    ;

  default = forVersion "1.31";
}

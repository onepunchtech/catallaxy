{ config, lib, ... }:

let
  inherit (lib) mkOption types;
  k8sLib = import ./lib/kubernetes/types.nix {
    inherit lib;
    k8sVersion = config.cluster.kubernetes.version;
  };

  resourcesIn =
    bundleName: bundle:
    lib.mapAttrsToList (resourceName: resource: {
      inherit bundleName resourceName resource;
    }) bundle.resources;

  declaredResources = lib.concatLists (lib.mapAttrsToList resourcesIn config.bundles);

  knownApiVersions = kind: k8sLib.generatedTypes.apiVersionsForKind k8sLib.typesByKind kind;

  exempt = config.cluster.kubernetes.uncheckedResources;

  isUnchecked =
    r:
    let
      known = knownApiVersions r.resource.kind;
    in
    r.resource.kind != ""
    && r.resource.apiVersion != ""
    && known != [ ]
    && !(builtins.elem r.resource.apiVersion known)
    && !(builtins.elem "${r.resource.apiVersion}/${r.resource.kind}" exempt);

  unchecked = builtins.filter isUnchecked declaredResources;
in
{
  options.bundles = mkOption {
    type = types.attrsOf k8sLib.bundleType;
    default = { };
    description = ''
      Installable bundles, keyed by name. The key is the bundle's
      identity everywhere else: `bundle:<name>` anchors, the
      `cluster.provisioning.rootBundles` list, and the per-bundle
      directory in the rendered manifest tree.
    '';
  };

  config.bundles = lib.mkMerge (lib.mapAttrsToList (_: floe: floe.bundles or { }) config.floes);

  config.assertions =
    map (r: {
      assertion = r.resource.kind != "";
      message =
        "bundles.${r.bundleName}.resources.${r.resourceName} declares no `kind`, "
        + "so nothing can say which Kubernetes type it is or check its spec";
    }) declaredResources
    ++ map (r: {
      assertion = r.resource.apiVersion != "";
      message =
        "bundles.${r.bundleName}.resources.${r.resourceName} declares no `apiVersion`, "
        + "so nothing can say which API it belongs to. A kind alone does not pick a "
        + "schema: `Cluster` is CloudNativePG's, Cluster API's and Crossplane's. Set it "
        + "to the group and version the CRD declares, such as \"postgresql.cnpg.io/v1\"";
    }) declaredResources
    ++ map (r: {
      assertion = false;
      message =
        "bundles.${r.bundleName}.resources.${r.resourceName} is apiVersion "
        + "\"${r.resource.apiVersion}\", kind \"${r.resource.kind}\". The schemas in this "
        + "tree know that kind only as: ${lib.concatStringsSep ", " (knownApiVersions r.resource.kind)}. Its spec is passed through unchecked, so it reads as validated and is not. "
        + "If the apiVersion is a typo, fix it. If the CRD genuinely is not here, ship "
        + "its schema (add a `crd` definition in lib/charts.nix, then run "
        + "`nix run .#generate-k8s-types`), or list "
        + "\"${r.resource.apiVersion}/${r.resource.kind}\" in "
        + "`cluster.kubernetes.uncheckedResources` to say so on purpose";
    }) unchecked;
}

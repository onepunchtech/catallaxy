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

  config.assertions = map (r: {
    assertion = r.resource.kind != "";
    message =
      "bundles.${r.bundleName}.resources.${r.resourceName} declares no `kind`, "
      + "so nothing can say which Kubernetes type it is or check its spec";
  }) declaredResources;
}

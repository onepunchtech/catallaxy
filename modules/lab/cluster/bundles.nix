{ config, lib, ... }:

let
  inherit (lib) mkOption types;
  k8sLib = import ./lib/kubernetes/types.nix {
    inherit lib;
    k8sVersion = config.cluster.kubernetes.version;
  };
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
}

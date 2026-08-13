{ lib }:

{
  directions = [ "teardown" ];
  idempotency = "idempotent";
  dialsLabEndpoints = false;
  dryRunSafe = false;
  params.options = {
    target = lib.mkOption {
      type = lib.types.str;
      description = "Cluster the managed resource represents.";
    };
    resourceKind = lib.mkOption {
      type = lib.types.str;
      description = "Fully qualified CRD kind of the managed resource.";
    };
    resourceName = lib.mkOption {
      type = lib.types.str;
      description = "Name of the managed resource to adopt.";
    };
    kubeContext = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Kube context holding the managed resource, which is the provisioning cluster rather than the target.";
    };
    externalNameDiscoveryBin = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Executable that recovers the provider's external name when the resource has lost it.";
    };
  };
}

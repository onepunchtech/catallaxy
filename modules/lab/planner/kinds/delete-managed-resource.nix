{ lib }:

{
  directions = [ "teardown" ];
  idempotency = "destructive";
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
      description = "Name of the managed resource to delete.";
    };
    wait = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Block until the resource is gone rather than returning once deletion is accepted.";
    };
    waitTimeoutSeconds = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Seconds to wait when `wait` is set.";
    };
    kubeContext = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Kube context holding the managed resource, which is the provisioning cluster rather than the target.";
    };
    externalNameDiscoveryBin = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Executable that recovers the provider's external name before deletion.";
    };
  };
}

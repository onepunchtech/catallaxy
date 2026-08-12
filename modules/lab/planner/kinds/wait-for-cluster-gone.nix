{ lib }:

{
  directions = [ "teardown" ];
  idempotency = "idempotent";
  dialsLabEndpoints = false;
  dryRunSafe = true;
  params.options = {
    target = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Cluster the managed resource represents.";
    };
    resourceKind = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Fully qualified CRD kind of the managed resource.";
    };
    resourceName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Name of the managed resource to wait on.";
    };
    waitTimeoutSeconds = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Seconds to wait for it to disappear.";
    };
    kubeContext = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Kube context holding the managed resource.";
    };
  };
}

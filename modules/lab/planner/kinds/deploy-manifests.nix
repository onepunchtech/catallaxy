{ lib }:

{
  directions = [ "deploy" ];
  idempotency = "idempotent";
  dialsLabEndpoints = false;
  dryRunSafe = false;
  params.options = {
    target = lib.mkOption {
      type = lib.types.str;
      description = "Cluster whose rendered manifests are applied.";
    };
    bootstrap = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Apply the bootstrap-stage subset only, for a cluster that is not yet reachable at its final address.";
    };
    kubeContext = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Kube context the step's kubectl calls run against. Defaults to the scoped cluster's runtime context.";
    };
  };
}

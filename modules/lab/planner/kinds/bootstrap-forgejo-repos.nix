{ lib }:

{
  directions = [ "deploy" ];
  idempotency = "idempotent";
  dialsLabEndpoints = true;
  dryRunSafe = false;
  params.options = {
    target = lib.mkOption {
      type = lib.types.str;
      description = "Cluster running the forgejo bootstrap Job.";
    };
    namespace = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Namespace forgejo runs in.";
    };
    jobLabelSelector = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Label selector identifying the bootstrap Job to wait on.";
    };
    kubeContext = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Kube context the step's kubectl calls run against. Defaults to the scoped cluster's runtime context.";
    };
  };
}

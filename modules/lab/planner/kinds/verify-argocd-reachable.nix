{ lib }:

{
  directions = [ "deploy" ];
  idempotency = "idempotent";
  dialsLabEndpoints = false;
  dryRunSafe = true;
  params.options = {
    target = lib.mkOption {
      type = lib.types.str;
      description = "Cluster whose pre-installed argocd is checked.";
    };
    namespace = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Namespace argocd runs in.";
    };
    kubeContext = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Kube context the step's kubectl calls run against. Defaults to the scoped cluster's runtime context.";
    };
  };
}

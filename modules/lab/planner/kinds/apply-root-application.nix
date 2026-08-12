{ lib }:

{
  directions = [ "deploy" ];
  idempotency = "idempotent";
  dialsLabEndpoints = true;
  dryRunSafe = false;
  params.options = {
    target = lib.mkOption {
      type = lib.types.str;
      description = "Cluster whose argocd receives the root Application.";
    };
    namespace = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Namespace argocd runs in.";
    };
    manifestPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path to the rendered root Application manifest, relative to the lab package.";
    };
    kubeContext = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Kube context the step's kubectl calls run against. Defaults to the scoped cluster's runtime context.";
    };
  };
}

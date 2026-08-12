{ lib }:

{
  directions = [ "deploy" ];
  idempotency = "idempotent";
  dialsLabEndpoints = false;
  dryRunSafe = false;
  params.options = {
    target = lib.mkOption {
      type = lib.types.str;
      description = "Cluster argocd is installed on.";
    };
    manifestRoot = lib.mkOption {
      type = lib.types.str;
      description = "Directory of bootstrap manifests to apply, relative to the lab package.";
    };
    fieldManager = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Server-side-apply field manager to own the applied objects.";
    };
    namespace = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Namespace to install argocd into.";
    };
    waitTimeoutSeconds = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Seconds to wait for the applied workloads to become ready.";
    };
    kubeContext = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Kube context the step's kubectl calls run against. Defaults to the scoped cluster's runtime context.";
    };
  };
}

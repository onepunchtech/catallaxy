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
    valuesPath = lib.mkOption {
      type = lib.types.str;
      description = "Path to the rendered Helm values file, relative to the lab package.";
    };
    chartRef = lib.mkOption {
      type = lib.types.str;
      description = "Helm chart reference, as in `argo/argo-cd`.";
    };
    releaseName = lib.mkOption {
      type = lib.types.str;
      description = "Helm release name.";
    };
    namespace = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Namespace to install argocd into.";
    };
    waitTimeoutSeconds = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Seconds to wait for the release to become ready.";
    };
    kubeContext = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Kube context the step's kubectl calls run against. Defaults to the scoped cluster's runtime context.";
    };
  };
}

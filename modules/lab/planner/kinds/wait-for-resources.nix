{ lib }:

{
  directions = [ "deploy" ];
  idempotency = "idempotent";
  dialsLabEndpoints = false;
  dryRunSafe = true;
  params.options = {
    target = lib.mkOption {
      type = lib.types.str;
      description = "Cluster holding the resources to wait on.";
    };
    resources = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.str);
      default = [ ];
      description = "Resources to wait for, each an attrset of selector fields.";
    };
    waitTimeoutSeconds = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Seconds to wait before the step fails.";
    };
    kubeContext = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Kube context the step's kubectl calls run against. Defaults to the scoped cluster's runtime context.";
    };
  };
}

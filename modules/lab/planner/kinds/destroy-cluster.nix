{ lib }:

{
  directions = [
    "deploy"
    "teardown"
  ];
  idempotency = "destructive";
  dialsLabEndpoints = false;
  dryRunSafe = false;
  params.options = {
    name = lib.mkOption {
      type = lib.types.str;
      description = "Cluster to destroy.";
    };
    provisioner = lib.mkOption {
      type = lib.types.str;
      description = "Provisioner that owns it.";
    };
    skipIfMissing = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Succeed rather than fail when the cluster is already gone.";
    };
  };
}

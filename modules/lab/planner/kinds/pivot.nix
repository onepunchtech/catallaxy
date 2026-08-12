{ lib }:

{
  directions = [ "deploy" ];
  idempotency = "oneShot";
  dialsLabEndpoints = false;
  dryRunSafe = false;
  params.options = {
    cluster = lib.mkOption {
      type = lib.types.str;
      description = "Cluster being migrated off its bootstrap address.";
    };
    bootstrapContext = lib.mkOption {
      type = lib.types.str;
      description = "Kube context the cluster is reachable at before the pivot.";
    };
    targetContext = lib.mkOption {
      type = lib.types.str;
      description = "Kube context the cluster is reachable at after it.";
    };
    provisioner = lib.mkOption {
      type = lib.types.str;
      description = "Provisioner of the bootstrap cluster.";
    };
  };
}

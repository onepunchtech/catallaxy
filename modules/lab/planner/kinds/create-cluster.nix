{ lib }:

{
  directions = [ "deploy" ];
  idempotency = "oneShot";
  dialsLabEndpoints = false;
  dryRunSafe = false;
  params.options = {
    name = lib.mkOption {
      type = lib.types.str;
      description = "Cluster to create.";
    };
    provisioner = lib.mkOption {
      type = lib.types.str;
      description = "Provisioner that creates it, as in `k3d` or `crossplane`.";
    };
  };
}

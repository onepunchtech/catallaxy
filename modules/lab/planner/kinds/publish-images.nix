{ lib }:

{
  directions = [ "deploy" ];
  idempotency = "idempotent";
  dialsLabEndpoints = true;
  dryRunSafe = false;
  params.options = {
    sourceCluster = lib.mkOption {
      type = lib.types.str;
      description = "Cluster hosting the registry the images are pushed to.";
    };
    images = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      description = "Image entries to publish, from `lab.out.publishImages`.";
    };
  };
}

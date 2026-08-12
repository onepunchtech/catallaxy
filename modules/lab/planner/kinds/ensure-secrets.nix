{ lib }:

{
  directions = [ "deploy" ];
  idempotency = "idempotent";
  dialsLabEndpoints = false;
  dryRunSafe = false;
  params.options = {
    stores = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Secret stores to generate and decrypt before the run begins.";
    };
  };
}

{ lib }:

{
  directions = [ "teardown" ];
  idempotency = "idempotent";
  dialsLabEndpoints = false;
  dryRunSafe = false;
  params.options = {
    zone = lib.mkOption {
      type = lib.types.str;
      description = "DNS zone whose resolver configuration is removed from this machine.";
    };
  };
}

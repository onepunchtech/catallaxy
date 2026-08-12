{ lib }:

{
  directions = [ "teardown" ];
  idempotency = "destructive";
  dialsLabEndpoints = false;
  dryRunSafe = false;
  params.options = { };
}

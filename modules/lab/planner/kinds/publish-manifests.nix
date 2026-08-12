{ lib }:

{
  directions = [ "deploy" ];
  idempotency = "idempotent";
  dialsLabEndpoints = true;
  dryRunSafe = false;
  params.options = { };
}

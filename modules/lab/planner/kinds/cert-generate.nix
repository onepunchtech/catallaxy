{ lib }:

{
  directions = [ "deploy" ];
  idempotency = "idempotent";
  dialsLabEndpoints = false;
  dryRunSafe = false;
  params.options = {
    zone = lib.mkOption {
      type = lib.types.str;
      description = "DNS zone the wildcard ingress certificate is minted for.";
    };
  };
}

{ lib }:

{
  directions = [ "deploy" ];
  idempotency = "idempotent";
  dialsLabEndpoints = false;
  dryRunSafe = false;
  params.options = {
    host = lib.mkOption {
      type = lib.types.str;
      description = "Address of the lab's CoreDNS.";
    };
    port = lib.mkOption {
      type = lib.types.int;
      description = "Port the lab's CoreDNS listens on.";
    };
    zone = lib.mkOption {
      type = lib.types.str;
      description = "DNS zone to point at it.";
    };
  };
}

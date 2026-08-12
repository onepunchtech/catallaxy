{ lib }:

{
  directions = [ "deploy" ];
  idempotency = "idempotent";
  dialsLabEndpoints = false;
  dryRunSafe = false;
  params.options = {
    port = lib.mkOption {
      type = lib.types.int;
      description = "Port the lab registry listens on.";
    };
    zone = lib.mkOption {
      type = lib.types.str;
      description = "DNS zone the registry is reachable under.";
    };
    upstreams = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Upstream registry hosts to mirror.";
    };
  };
}

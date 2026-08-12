{ lib }:

{
  directions = [ "deploy" ];
  idempotency = "idempotent";
  dialsLabEndpoints = false;
  dryRunSafe = false;
  params.options = {
    subnet = lib.mkOption {
      type = lib.types.str;
      description = "Lab subnet in CIDR form to route through the Colima VM.";
    };
    profile = lib.mkOption {
      type = lib.types.str;
      description = "Colima profile hosting the lab's docker daemon.";
    };
  };
}

{ lib }:

{
  directions = [ "deploy" ];
  idempotency = "idempotent";
  dialsLabEndpoints = false;
  dryRunSafe = false;
  params.options = {
    name = lib.mkOption {
      type = lib.types.str;
      description = "Docker network to create.";
    };
    subnet = lib.mkOption {
      type = lib.types.str;
      description = "Subnet in CIDR form.";
    };
    gateway = lib.mkOption {
      type = lib.types.str;
      description = "Gateway address within the subnet.";
    };
  };
}

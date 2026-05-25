{ config, lib, ... }:

let
  inherit (lib) mkOption types;
in
{
  options.lab.network = {
    dockerSubnet = mkOption {
      type = types.str;
      default = "172.19.0.0/16";
      description = ''
        Subnet for the lab
      '';
    };
  };
}

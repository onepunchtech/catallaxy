{ lib, ... }:

let
  inherit (lib) mkOption types;
in
{
  options.floes.my-floe = {
    image = mkOption {
      type = types.str;
      default = "nginx:1.27-alpine";
      description = "Container image to run. Pin a tag, never `latest`.";
    };

    replicas = mkOption {
      type = types.ints.positive;
      default = 1;
      description = "Number of replicas.";
    };
  };
}

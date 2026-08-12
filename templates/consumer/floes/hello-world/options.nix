{ lib, ... }:

let
  inherit (lib) mkOption types;
in
{
  options.floes.hello-world = {
    image = mkOption {
      type = types.str;
      default = "hashicorp/http-echo:1.0.0";
      description = "Container image to run. Pin a tag, never `latest`: the `image-pin` lint rule enforces this when `lab.images.requireDigest` is on.";
    };

    message = mkOption {
      type = types.str;
      default = "Hello from catallaxy!";
      description = "Text the app echoes back.";
    };

    replicas = mkOption {
      type = types.ints.positive;
      default = 1;
      description = "Number of replicas.";
    };

    domain = mkOption {
      type = types.str;
      description = "Public hostname the HTTPRoute attaches to.";
    };
  };
}

{ lib }:

let
  inherit (lib) mkOption types;

  capabilityType = types.submodule {
    freeformType = types.attrsOf types.raw;
    options = { };
  };

  capabilitiesType = types.submodule {
    options.provides = mkOption {
      type = types.attrsOf capabilityType;
      default = { };
      example = lib.literalExpression "{ api-gateway = { }; }";
      description = ''
        Jobs this floe does, each holding what it offers for that job, so a
        consumer can reach it without naming the floe.

        Declaring one does not order anything and does not refuse a second
        provider. Say that on the bundle: `provides` puts the name in the
        dependency graph and `conflicts` refuses a second provider of it.
      '';
    };
  };
in
{
  inherit capabilitiesType;
}

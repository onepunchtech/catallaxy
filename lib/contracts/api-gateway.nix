{ lib }:

let
  inherit (lib) mkOption types;

  contractOptions = {
    routing = mkOption {
      type = (import ./routing.nix { inherit lib; }).routingOption.type;
      description = ''
        The readiness tokens anything emitting a route gates on.

        No default, so it is required: a floe claiming this job and not
        saying how to wait for it is the case that used to resolve to null
        and leave every consumer with no edge.
      '';
    };

    internalEnabled = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether an internal-tier Gateway is on, so a consumer can ask for a
        hostname that resolves only inside the lab.

        Part of the contract rather than of either implementation, so what a
        consumer may read is what the job answers and not what one provider
        happens to expose beside it.

        False by default, because an implementation with no second tier
        should answer a straight no rather than leave a consumer reading a
        field that is not there.
      '';
    };
  };

  required = lib.attrNames (lib.filterAttrs (_: option: !(option ? default)) contractOptions);

  declared = lib.attrNames contractOptions;
in
{
  apiGateway = {
    options = contractOptions;

    claim =
      payload:
      let
        given = lib.attrNames payload;
        unknown = lib.subtractLists declared given;
        missing = lib.subtractLists given required;
      in
      if unknown != [ ] then
        throw ''
          api-gateway: ${lib.concatStringsSep " and " (map (f: "`${f}`") unknown)} ${
            if lib.length unknown == 1 then "is not a field" else "are not fields"
          } of this capability.

          It declares ${lib.concatStringsSep ", " (map (f: "`${f}`") declared)}.
          A consumer reads what the contract says is there, so anything else
          is a field it would never look at.

          Put it in the floe's own `exports` if it belongs to this
          implementation rather than to the job.
        ''
      else if missing != [ ] then
        throw ''
          api-gateway: nothing supplied ${
            lib.concatStringsSep " and " (map (f: "`${f}`") missing)
          }, which this capability requires.

          A floe claiming a job answers for all of it. Leaving a required
          field out used to resolve to null, so every consumer of it silently
          got no answer and no edge.
        ''
      else
        (lib.evalModules {
          modules = [
            { options = contractOptions; }
            payload
          ];
        }).config;
  };
}

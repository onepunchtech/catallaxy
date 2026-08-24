{ lib }:

let
  refs = (import ../floe { inherit lib; }).refs;
in
{
  routingOption = lib.mkOption {
    type = refs.mkCapability {
      publicReady = refs.tokenOption ''
        "The public Gateway is programmed and accepting routes."
        Anything emitting an HTTPRoute/GRPCRoute against it gates on
        this.
      '';
      controllerReady = refs.tokenOption ''
        "The Gateway API controller is running." Weaker than
        `publicReady`; enough to apply a Gateway, not enough for a
        route to serve traffic.
      '';
    };
    default = null;
    description = ''
      Gateway API routing, or null when this floe is not providing it.
      Consumers assert on this rather than on any floe's `enable`: the
      question is "will my HTTPRoute have a parent", which is ours.

      Declared here rather than in one floe because more than one implements
      it, and a consumer reaching it through `capabilities.api-gateway` gets
      whichever is enabled. Two floes answering the same question with
      differently shaped answers is the failure this shares a type to avoid.
    '';
  };
}

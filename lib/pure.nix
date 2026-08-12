{ lib }:

let
  evalMod = import ./eval/module.nix { inherit lib; };
in
{
  inherit (evalMod) evalModule;
  inherit (import ./util/network.nix { inherit lib; }) network;
  inherit (import ./util/idempotent-job.nix { inherit lib; }) mkIdempotentJob hashContent;

  floe = import ./floe { inherit lib; };

  planTokens = import ./plan-tokens.nix { inherit lib; };

  inherit (import ./util/kapp.nix { inherit lib; }) mkPreserveRuntimePatches;

  mkNetworkPolicy =
    {
      name,
      namespace,
      podSelector ? { },
      policyTypes ? [
        "Ingress"
        "Egress"
      ],
      ingress ? [ ],
      egress ? [ ],
    }:
    {
      apiVersion = "networking.k8s.io/v1";
      kind = "NetworkPolicy";
      metadata = {
        inherit name namespace;
        labels."app.kubernetes.io/managed-by" = "catallaxy";
      };
      spec = {
        inherit podSelector policyTypes;
      }
      // lib.optionalAttrs (ingress != [ ]) { inherit ingress; }
      // lib.optionalAttrs (egress != [ ]) { inherit egress; };
    };
}

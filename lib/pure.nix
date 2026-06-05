# Pure library — no pkgs dependency, works on any system.
# Contains the stable API for downstream consumers.
{ lib }:

let
  evalMod = import ./eval/module.nix { inherit lib; };
in
{
  inherit (evalMod) evalModule;
  inherit (import ./util/network.nix { inherit lib; }) network;
  phases = import ./util/phases.nix;

  ## Helper for writing custom components that follow the established pattern.
  mkComponent =
    {
      name,
      phase ? "apps",
      options ? { },
      module,
    }:
    {
      config,
      lib,
      ...
    }:
    let
      cfg = config.components.${name};
    in
    {
      options.components.${name} = {
        enable = lib.mkEnableOption "the ${name} component";
        phase = lib.mkOption {
          type = lib.types.str;
          default = phase;
          description = "Deployment phase for ${name}";
        };
        namespace = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Kubernetes namespace for ${name}";
        };
        version = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Version of ${name}";
        };
        ref = lib.mkOption {
          type = lib.types.attrs;
          default = { };
          description = "Computed references for ${name}";
        };
      }
      // options;

      config = lib.mkIf cfg.enable (module cfg);
    };

  ## Helper for generating Kubernetes NetworkPolicy resources.
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

{ lib }:

let
  inherit (lib) mkOption types;
in
{
  gatewayOptions =
    {
      lab,
      withMode ? false,
    }:
    {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Attach this floe to a Gateway, so it is reachable from outside the cluster.";
      };

      gatewayRef = mkOption {
        type = types.str;
        default = "default-gateway";
        description = "Name of the Gateway resource to attach to (public tier).";
      };

      gatewayNamespace = mkOption {
        type = types.nullOr types.str;
        default = "kube-system";
        description = "Namespace of the Gateway resource";
      };

      tier = mkOption {
        type = types.enum [
          "public"
          "internal"
        ];
        default = lab.policy.exposure.defaultTier or "public";
        description = ''
          Lab network tier to attach to. `internal` points at
          `floes.gateway.exports.internalGatewayName`. Requires
          `floes.gateway.internal.enable = true` on the cluster.
        '';
      };
    }
    // lib.optionalAttrs withMode {
      mode = mkOption {
        type = types.enum [
          "terminate"
          "passthrough"
        ];
        default = "terminate";
        description = "TLS mode: 'terminate' uses HTTPRoute + BackendTLSPolicy, 'passthrough' uses TLSRoute (raw TLS to backend)";
      };
    };
}

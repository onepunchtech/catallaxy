{ lib }:

let
  inherit (lib) mkOption types;
in
{
  gatewayOptions =
    {
      config,
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
        default = config.floes.gateway.exports.gatewayName;
        defaultText = lib.literalExpression "config.floes.gateway.exports.gatewayName";
        description = ''
          Name of the Gateway resource to attach to (public tier).

          Follows the gateway floe rather than restating its name. A
          literal default here is a second copy of a fact the gateway
          floe already publishes, and the two only agree by coincidence:
          renaming `floes.gateway.gatewayName` left every public-tier
          route pointing at a Gateway that was never created, and no
          check caught it (2026-08-23).
        '';
      };

      gatewayNamespace = mkOption {
        type = types.nullOr types.str;
        default = config.floes.gateway.exports.namespace;
        defaultText = lib.literalExpression "config.floes.gateway.exports.namespace";
        description = "Namespace of the Gateway resource.";
      };

      tier = mkOption {
        type = types.enum [
          "public"
          "internal"
        ];
        default = config.floes.gateway.exports.defaultTier;
        defaultText = lib.literalExpression "config.floes.gateway.exports.defaultTier";
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

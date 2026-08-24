{
  config,
  lab,
  lib,
  ...
}:

let
  inherit (lib) mkOption types;

  customAppType = types.submodule (
    { name, ... }:
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Render this app. Set false to keep the declaration and stop deploying it.";
        };

        namespace = mkOption {
          type = types.str;
          default = name;
          description = "Kubernetes namespace (defaults to app name)";
        };

        createNamespace = mkOption {
          type = types.bool;
          default = true;
          description = "Create the namespace as part of this app's bundle, rather than expecting something else to.";
        };

        helmCharts = mkOption {
          type = types.attrsOf types.attrs;
          default = { };
          description = "Helm charts to deploy (same shape as phase bundle helmCharts)";
        };

        resources = mkOption {
          type = types.attrsOf types.attrs;
          default = { };
          description = "Typed Kubernetes resources";
        };

        yamls = mkOption {
          type = types.listOf (types.either types.str types.path);
          default = [ ];
          description = "Raw YAML manifests";
        };

        gateway = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = "Attach the app to a Gateway, so it is reachable from outside the cluster.";
          };
          mode = mkOption {
            type = types.enum [
              "terminate"
              "passthrough"
            ];
            default = "terminate";
            description = "TLS handling. `terminate` ends TLS at the gateway and forwards plaintext; `passthrough` hands the connection to the backend, which then owns the certificate.";
          };
          domain = mkOption {
            type = types.str;
            default = "";
            description = "Hostname to route. Empty renders no route.";
          };
          serviceName = mkOption {
            type = types.str;
            default = name;
            description = "Backend service name for the HTTPRoute/TLSRoute";
          };
          servicePort = mkOption {
            type = types.port;
            default = 80;
            description = "Port on the app's Service that the route forwards to.";
          };
          gatewayRef = mkOption {
            type = types.str;
            default = "default-gateway";
            description = "Name of the Gateway resource to attach to (public tier).";
          };
          gatewayNamespace = mkOption {
            type = types.nullOr types.str;
            default = "kube-system";
            description = "Namespace of the Gateway resource.";
          };
          tier = mkOption {
            type = types.enum [
              "public"
              "internal"
            ];

            default = config.floes.gateway.exports.defaultTier;
            defaultText = lib.literalExpression "config.floes.gateway.exports.defaultTier";
            description = "Lab network tier (public | internal).";
          };
        };
      };
    }
  );
in
{

  options.floes.custom = {
    apps = mkOption {
      type = types.attrsOf customAppType;
      default = { };
      description = ''
        Custom applications to deploy. Each app gets its own bundle
        within the specified phase. Supports Helm charts, typed resources,
        raw YAML, and optional Gateway API routing.
      '';
    };
  };
}

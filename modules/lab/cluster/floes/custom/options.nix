{
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
        };

        namespace = mkOption {
          type = types.str;
          default = name;
          description = "Kubernetes namespace (defaults to app name)";
        };

        createNamespace = mkOption {
          type = types.bool;
          default = true;
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
          };
          mode = mkOption {
            type = types.enum [
              "terminate"
              "passthrough"
            ];
            default = "terminate";
          };
          domain = mkOption {
            type = types.str;
            default = "";
          };
          serviceName = mkOption {
            type = types.str;
            default = name;
            description = "Backend service name for the HTTPRoute/TLSRoute";
          };
          servicePort = mkOption {
            type = types.port;
            default = 80;
          };
          gatewayRef = mkOption {
            type = types.str;
            default = "default-gateway";
          };
          gatewayNamespace = mkOption {
            type = types.nullOr types.str;
            default = "kube-system";
          };
          tier = mkOption {
            type = types.enum [
              "public"
              "internal"
            ];

            default = lab.policy.exposure.defaultTier or "public";
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

{
  config,
  lib,
  ...
}:

let
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    mapAttrs
    mapAttrsToList
    concatMapAttrs
    optionalAttrs
    ;

  # Submodule for a single custom app
  customAppType = types.submodule (
    { name, config, ... }:
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = true;
        };

        phase = mkOption {
          type = types.str;
          default = "apps";
          description = "Deployment phase (apps, workloads, infrastructure, etc.)";
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
        };
      };
    }
  );

  # Generate gateway route resource for a custom app
  mkRouteResource =
    name: app:
    let
      parentRef = {
        name = app.gateway.gatewayRef;
      }
      // optionalAttrs (app.gateway.gatewayNamespace != null) {
        namespace = app.gateway.gatewayNamespace;
      }
      // optionalAttrs (app.gateway.mode == "passthrough") {
        sectionName = "tls-passthrough";
      };
    in
    if app.gateway.mode == "passthrough" then
      {
        "${name}-tlsroute" = {
          apiVersion = "gateway.networking.k8s.io/v1alpha2";
          kind = "TLSRoute";
          metadata = {
            inherit name;
            namespace = app.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          spec = {
            parentRefs = [ parentRef ];
            hostnames = [ app.gateway.domain ];
            rules = [
              {
                backendRefs = [
                  {
                    name = app.gateway.serviceName;
                    port = app.gateway.servicePort;
                  }
                ];
              }
            ];
          };
        };
      }
    else
      {
        "${name}-httproute" = {
          apiVersion = "gateway.networking.k8s.io/v1";
          kind = "HTTPRoute";
          metadata = {
            inherit name;
            namespace = app.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          spec = {
            parentRefs = [ parentRef ];
            hostnames = [ app.gateway.domain ];
            rules = [
              {
                matches = [
                  {
                    path = {
                      type = "PathPrefix";
                      value = "/";
                    };
                  }
                ];
                backendRefs = [
                  {
                    name = app.gateway.serviceName;
                    port = app.gateway.servicePort;
                  }
                ];
              }
            ];
          };
        };
      };
in
{
  options.components.custom = {
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

  config = {
    # Write each enabled custom app into its phase as a bundle
    phases = concatMapAttrs (
      name: app:
      if app.enable then
        {
          ${app.phase}.bundles."custom-${name}" = {
            helmCharts = mapAttrs (
              chartName: chartCfg:
              chartCfg
              // {
                namespace = chartCfg.namespace or app.namespace;
              }
            ) app.helmCharts;

            resources =
              app.resources
              // (if app.gateway.enable && app.gateway.domain != "" then mkRouteResource name app else { });

            yamls = app.yamls;

            createNamespaces = if app.createNamespace then [ app.namespace ] else [ ];
          };
        }
      else
        { }
    ) config.components.custom.apps;
  };
}

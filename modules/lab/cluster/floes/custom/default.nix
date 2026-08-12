{
  config,
  lib,
  pkgs,
  cataCharts,
  k8sSpecs,
  k8sHelpers,
  ...
}@__floeModuleArgs:

let
  inherit ((import ../../../../../lib/floe { inherit lib; })) mkFloe;
in
(mkFloe {
  name = "custom";

  imports = [ ./options.nix ];

  requires = [ "gateway" ];
  module =
    {
      config,
      lib,
      cfg,
      ...
    }:
    let
      inherit (lib)
        mapAttrs
        concatMapAttrs
        optionalAttrs
        ;

      mkRouteResource =
        name: app:
        let
          parentRef = {
            name =
              if app.gateway.tier == "internal" then
                config.floes.gateway.exports.internalGatewayName
              else
                app.gateway.gatewayRef;
          }
          // optionalAttrs (app.gateway.gatewayNamespace != null) {
            namespace = app.gateway.gatewayNamespace;
          }
          // optionalAttrs (app.gateway.mode == "passthrough") {
            sectionName = "tls-passthrough";
          }

          // optionalAttrs (app.gateway.mode != "passthrough") {
            sectionName = config.floes.gateway.exports.terminatingListenerName or "https";
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

      bundles = concatMapAttrs (
        name: app:
        if app.enable then
          {
            "custom-${name}" = {
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
      ) cfg.apps;

      floes.gateway.internalHostnames = lib.concatLists (
        lib.mapAttrsToList (
          _name: app:
          lib.optional (
            app.enable && app.gateway.enable && app.gateway.tier == "internal" && app.gateway.domain != ""
          ) app.gateway.domain
        ) cfg.apps
      );
    };
})
  __floeModuleArgs

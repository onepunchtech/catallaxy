{
  config,
  lib,
  pkgs,
  cataCharts,
  k8sSpecs,
  k8sHelpers,
  lab,
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
          parentRef = k8sHelpers.mkGatewayParentFor {
            inherit (app) gateway;
            inherit (config.floes.gateway.exports) internalGatewayName;
            sectionName =
              if app.gateway.mode == "passthrough" then
                "tls-passthrough"
              else
                config.floes.gateway.exports.terminatingListenerName or "https";
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
      # No `imagesComplete` here, and not by oversight. Every other floe
      # curates a fixed set of software, so it can name every image it
      # renders. This one renders charts and resources a lab hands it, so the
      # images are the lab's and only the lab can say what they are. Claiming
      # completeness would be claiming to know something this floe cannot.

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

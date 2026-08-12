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
  name = "redis-operator";
  version = "0.18.0";
  imports = [ ./options.nix ];
  module =
    { cfg, ... }:
    {
      bundles.redis-operator = {
        includeInBootstrap = false;
        helmCharts.redis-operator = {
          chart = cfg.chart;
          releaseName = "redis-operator";
          namespace = cfg.namespace;
          createNamespace = true;
          values = { };
        };
        createNamespaces = [ cfg.namespace ];

        provides = [ "redis-operator/ready" ];
        readyProbe = {
          kind = "condition";
          resource = "deployment/redis-operator";
          namespace = cfg.namespace;
          condition = "Available";
          timeout = "3m";
        };
      };
    };
})
  __floeModuleArgs

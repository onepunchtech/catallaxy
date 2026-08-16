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
  name = "redis-operator";
  version = "0.18.0";
  imports = [ ./options.nix ];
  module =
    { cfg, ... }:
    {
      floes.redis-operator.network = {
        declared = true;
      };

      floes.redis-operator.imagesComplete = true;

      floes.redis-operator.images.operator = {
        registry = "ghcr.io";
        repository = "ot-container-kit/redis-operator/redis-operator";
        tag = "v0.18.0";
      };

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

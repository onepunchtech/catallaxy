{
  config,
  lib,
  pkgs,
  cataCharts,
  k8sSpecs,
  k8sHelpers,
  lab,
  ...
}:

let
  inherit ((import ../../../../../lib/floe { inherit lib; })) floeOptions;
  cfg = config.floes.redis-operator;
in
{
  imports = [
    (floeOptions {
      name = "redis-operator";
      version = "0.18.0";
    })
    ./options.nix
  ];

  config = lib.mkIf cfg.enable {
    floes.redis-operator.network = {
      declared = true;
    };

    floes.redis-operator.imagesComplete = true;

    floes.redis-operator.images.operator = {
      registry = "ghcr.io";
      repository = "ot-container-kit/redis-operator/redis-operator";
      tag = "v0.18.0";
    };

    floes.redis-operator.bundles.redis-operator = {
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
}

{
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption mkDefault types;
in
{
  config.floes.trust-manager.namespace = mkDefault "cert-manager";

  options.floes.trust-manager = {
    chart = mkOption {
      type = types.package;
      default = cataCharts.trust-manager.chart;
      description = "Helm chart to install. Defaults to the chart catallaxy pins.";
    };
  };
}

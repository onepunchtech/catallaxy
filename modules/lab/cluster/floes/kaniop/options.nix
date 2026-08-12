{
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption mkDefault types;
in
{

  config.floes.kaniop.namespace = mkDefault "kanidm";

  options.floes.kaniop = {
    chart = mkOption {
      type = types.package;
      default = cataCharts.kaniop.chart;
      description = "Custom chart derivation. When null, uses OCI chart.";
    };
  };
}

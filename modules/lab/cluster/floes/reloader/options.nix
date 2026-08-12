{
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption types;
in
{
  options.floes.reloader = {
    chart = mkOption {
      type = types.package;
      default = cataCharts.reloader.chart;
    };
  };
}

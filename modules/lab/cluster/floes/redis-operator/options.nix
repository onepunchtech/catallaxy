{
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption types;
in
{
  options.floes.redis-operator = {
    chart = mkOption {
      type = types.package;
      default = cataCharts.redis-operator.chart;
      description = "Custom chart derivation. When null, uses nixhelm default.";
    };
  };
}

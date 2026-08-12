{
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption types;
in
{
  options.floes.external-secrets = {
    chart = mkOption {
      type = types.package;
      default = cataCharts.external-secrets.chart;
      description = "External Secrets Helm chart derivation (default: cataCharts.external-secrets)";
    };

    extraValues = mkOption {
      type = types.attrs;
      default = { };
      description = "Additional Helm values to merge into the External Secrets chart release.";
    };
  };
}

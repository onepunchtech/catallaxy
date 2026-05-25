# trust-manager — distributes CA bundles across namespaces
#
# Works with cert-manager's self-signed CA to make the lab CA
# available in any namespace that needs it. Components opt-in
# by referencing cert-manager.ref.caBundleConfigMap.

{
  config,
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    ;
  cfg = config.components.trust-manager;
in
{
  options.components.trust-manager = {
    enable = mkEnableOption "trust-manager (CA bundle distribution)";

    phase = mkOption {
      type = types.str;
      default = "operators";
    };

    chart = mkOption {
      type = types.package;
      default = cataCharts.trust-manager.chart;
    };

    namespace = mkOption {
      type = types.str;
      default = "cert-manager";
    };

    ref = mkOption {
      type = types.attrs;
      readOnly = true;
    };
  };

  config = lib.mkMerge [
    {
      components.trust-manager.ref = {
        namespace = cfg.namespace;
      };
    }

    (mkIf cfg.enable {
      phases.${cfg.phase}.bundles.trust-manager.helmCharts.trust-manager = {
        chart = cfg.chart;
        releaseName = "trust-manager";
        namespace = cfg.namespace;
        values = {
          app.trust.namespace = cfg.namespace;
        };
      };
    })
  ];
}

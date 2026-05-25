# modules/cluster/components/redis-operator.nix
#
# Redis operator component — merged high-level options + IR writer.
#
# Provides Redis lifecycle management via Kubernetes CRDs.

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
  cfg = config.components.redis-operator;

  # Chart reference with fallback
  chartRef = cfg.chart;
in
{
  # =========================================================================
  # PART 1: High-level options
  # =========================================================================

  options.components.redis-operator = {
    enable = mkEnableOption "Redis operator";

    phase = mkOption {
      type = types.str;
      default = "operators";
      description = "Deployment phase this component belongs to";
    };

    version = mkOption {
      type = types.str;
      default = "0.18.0";
      description = "Redis operator chart version";
    };

    namespace = mkOption {
      type = types.str;
      default = "redis-operator";
      description = "Namespace for the Redis operator";
    };

    chart = mkOption {
      type = types.package;
      default = cataCharts.redis-operator.chart;
      description = "Custom chart derivation. When null, uses nixhelm default.";
    };

    # Computed refs
    ref = mkOption {
      type = types.attrs;
      readOnly = true;
      description = "Computed references for Redis operator";
    };
  };

  # =========================================================================
  # PART 2: Computed refs
  # =========================================================================

  # =========================================================================
  # PART 3: Phase writer
  # =========================================================================

  config = lib.mkMerge [
    {
      components.redis-operator.ref = {
        namespace = cfg.namespace;
      };
    }
    (mkIf cfg.enable {
      phases.${cfg.phase}.bundles.redis-operator = {
        # Redis operator helm chart
        helmCharts.redis-operator = {
          chart = chartRef;
          releaseName = "redis-operator";
          namespace = cfg.namespace;
          createNamespace = true;
          values = { };
        };

        # Namespace creation
        createNamespaces = [ cfg.namespace ];
      };
    })
  ];
}

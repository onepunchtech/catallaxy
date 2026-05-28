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
  cfg = config.components.external-secrets;

  # Chart reference with fallback
  chartRef = cfg.chart;
in
{
  # =========================================================================
  # PART 1: High-level options
  # =========================================================================

  options.components.external-secrets = {
    enable = mkEnableOption "External Secrets Operator";

    phase = mkOption {
      type = types.str;
      default = "secrets";
      description = "Deployment phase this component belongs to";
    };

    version = mkOption {
      type = types.str;
      default = "0.10.0";
      description = "External Secrets Operator version";
    };

    chart = mkOption {
      type = types.package;
      default = cataCharts.external-secrets.chart;
      description = "External Secrets Helm chart derivation (default: cataCharts.external-secrets)";
    };

    namespace = mkOption {
      type = types.str;
      default = "external-secrets";
      description = "Namespace for External Secrets Operator";
    };

    # Computed refs for other components to reference
    ref = mkOption {
      type = types.attrs;
      readOnly = true;
      description = "Computed references for External Secrets Operator";
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
      components.external-secrets.ref = {
        namespace = cfg.namespace;
      };
    }
    (mkIf cfg.enable {
      # Install CRDs declaratively in the crds phase
      phases.crds.bundles.external-secrets-crds.yamls = [ cataCharts.external-secrets.crds ];

      phases.${cfg.phase}.bundles.external-secrets = {
        # Main External Secrets helm chart
        helmCharts.external-secrets = {
          chart = chartRef;
          releaseName = "external-secrets";
          namespace = cfg.namespace;
          createNamespace = true;
          values = {
            installCRDs = false;
          };
        };

        # Namespace creation
        createNamespaces = [ cfg.namespace ];
      };
    })
  ];
}

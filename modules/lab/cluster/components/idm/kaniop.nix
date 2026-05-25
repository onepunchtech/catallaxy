# modules/cluster/components/kaniop.nix
#
# Kaniop operator component — merged high-level options + IR writer.
#
# Manages Kanidm lifecycle declaratively via Kubernetes CRDs
# (KanidmPersonAccount, KanidmGroup, KanidmOAuth2Client).

{
  config,
  lib,
  pkgs,
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
  cfg = config.components.kaniop;

  # Chart reference with fallback
  chartRef = cfg.chart;

  # Extract CRDs from the chart as a standalone derivation
  kaniopCrds = pkgs.runCommand "kaniop-crds" { } ''
    cp ${chartRef}/crds/crds.yaml $out
  '';
in
{
  # =========================================================================
  # PART 1: High-level options
  # =========================================================================

  options.components.kaniop = {
    enable = mkEnableOption "Kaniop operator for declarative Kanidm management";

    phase = mkOption {
      type = types.str;
      default = "operators";
      description = "Deployment phase this component belongs to";
    };

    version = mkOption {
      type = types.str;
      default = "0.6.1";
      description = "Kaniop operator version";
    };

    namespace = mkOption {
      type = types.str;
      default = "kanidm";
      description = "Namespace for Kaniop operator (same as Kanidm)";
    };

    chart = mkOption {
      type = types.package;
      default = cataCharts.kaniop.chart;
      description = "Custom chart derivation. When null, uses OCI chart.";
    };

    ref = mkOption {
      type = types.attrs;
      readOnly = true;
      description = "Computed references for Kaniop";
    };
  };

  # =========================================================================
  # PART 2: Computed refs and config
  # =========================================================================

  config = lib.mkMerge [
    {
      components.kaniop.ref = {
        namespace = cfg.namespace;
      };
    }

    # =========================================================================
    # PART 3: Phase writer
    # =========================================================================

    (mkIf cfg.enable {
      # Install kaniop CRDs in the crds phase so the operator doesn't crash
      # waiting for its own CRD API endpoints.
      # Helm template skips crds/ directory, so we copy the file directly.
      phases.crds.bundles.kaniop-crds.yamls = [ kaniopCrds ];

      phases.${cfg.phase}.bundles.kaniop = {
        # Kaniop helm chart
        helmCharts.kaniop = {
          chart = chartRef;
          releaseName = "kaniop";
          namespace = cfg.namespace;
          createNamespace = true;
          values = {
            image.tag = cfg.version;
          };
        };

        createNamespaces = [ cfg.namespace ];
      };
    })
  ];
}

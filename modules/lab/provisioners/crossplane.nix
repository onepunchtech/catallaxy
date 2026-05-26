{ config, lib, ... }:

let
  inherit (lib) mkOption mkEnableOption types;
in
{
  options.provisioner.crossplane = {
    phase = mkOption {
      type = types.str;
      default = "infrastructure";
      description = "Deployment phase this component belongs to";
    };

    version = mkOption {
      type = types.str;
      default = "1.17.0";
      description = "Crossplane version";
    };

    chart = mkOption {
      type = types.nullOr types.package;
      default = null;
      description = "Crossplane Helm chart derivation (default: cataCharts.crossplane)";
    };

    namespace = mkOption {
      type = types.str;
      default = "crossplane-system";
      description = "Namespace for Crossplane";
    };

    providers = mkOption {
      type = types.listOf (
        types.enum [
          "kubernetes"
          "helm"
          "aws"
          "gcp"
          "azure"
          "hetzner"
        ]
      );
      default = [
        "kubernetes"
        "helm"
      ];
      description = "Crossplane providers to install";
    };
  };
}

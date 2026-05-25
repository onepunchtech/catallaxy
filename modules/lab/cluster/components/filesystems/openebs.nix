# modules/cluster/components/openebs.nix
#
# OpenEBS storage operator component — merged high-level options + IR writer.
#
# Provides dynamic PV provisioning via various storage engines.
# Currently uses Rancher local-path-provisioner for simple local storage.

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
  cfg = config.components.openebs;

  # Chart reference - uses local-path-provisioner
  chartRef = cfg.chart;

  storageClassType = types.submodule {
    options = {
      isDefault = mkOption {
        type = types.bool;
        default = false;
        description = "Set as the cluster's default StorageClass";
      };

      reclaimPolicy = mkOption {
        type = types.enum [
          "Delete"
          "Retain"
        ];
        default = "Delete";
        description = "PV reclaim policy";
      };

      volumeBindingMode = mkOption {
        type = types.enum [
          "WaitForFirstConsumer"
          "Immediate"
        ];
        default = "WaitForFirstConsumer";
        description = "Volume binding mode";
      };
    };
  };
in
{
  # =========================================================================
  # PART 1: High-level options
  # =========================================================================

  options.components.openebs = {
    enable = mkEnableOption "OpenEBS storage operator";

    phase = mkOption {
      type = types.str;
      default = "operators";
      description = "Deployment phase this component belongs to";
    };

    version = mkOption {
      type = types.str;
      default = "4.1.1";
      description = "OpenEBS version";
    };

    namespace = mkOption {
      type = types.str;
      default = "openebs";
      description = "Namespace for OpenEBS";
    };

    chart = mkOption {
      type = types.package;
      default = cataCharts.local-path-provisioner.chart;
      description = "Custom chart derivation. When null, uses nixhelm default.";
    };

    engine = mkOption {
      type = types.enum [
        "hostpath"
        "lvm"
        "zfs"
        "mayastor"
      ];
      default = "hostpath";
      description = ''
        Storage engine:
        - hostpath: local path provisioner (dev/single-node)
        - lvm: LVM-based local storage
        - zfs: ZFS-based local storage
        - mayastor: replicated NVMe-oF storage (production HA)
      '';
    };

    storageClasses = mkOption {
      type = types.attrsOf storageClassType;
      default = {
        openebs-default = {
          isDefault = true;
        };
      };
      description = "StorageClass definitions to create";
    };

    mayastor = {
      replicas = mkOption {
        type = types.ints.positive;
        default = 3;
        description = "Number of Mayastor IO engine replicas";
      };

      cpuCount = mkOption {
        type = types.ints.positive;
        default = 2;
        description = "CPU cores allocated to each Mayastor instance";
      };
    };

    ref = mkOption {
      type = types.attrs;
      readOnly = true;
      description = "Computed references for OpenEBS";
    };
  };

  # =========================================================================
  # PART 2: Computed refs
  # =========================================================================

  config = lib.mkMerge [
    {
      components.openebs.ref =
        let
          defaultSC = lib.findFirst (name: cfg.storageClasses.${name}.isDefault) (builtins.head (
            builtins.attrNames cfg.storageClasses
          )) (builtins.attrNames cfg.storageClasses);
        in
        {
          storageClassName = defaultSC;
          namespace = cfg.namespace;
        };
    }

    # =========================================================================
    # PART 3: Phase writer
    # =========================================================================

    (mkIf cfg.enable {
      phases.${cfg.phase}.bundles.openebs = {
        # Local path provisioner helm chart
        helmCharts.openebs = {
          chart = chartRef;
          releaseName = "local-path-provisioner";
          namespace = cfg.namespace;
          createNamespace = true;
          values = {
            storageClass = {
              name = "local-path";
              defaultClass = true;
            };
          };
        };

        # Namespace creation
        createNamespaces = [ cfg.namespace ];
      };
    })
  ];
}

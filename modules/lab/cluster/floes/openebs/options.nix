{
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption types;

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
  options.floes.openebs = {
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
  };
}

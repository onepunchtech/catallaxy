# modules/provisioners/docker.nix
#
# Docker provisioner for Talos-in-Docker clusters.

{ config, lib, ... }:

let
  cfg = config.provisioner.docker;
  inherit (lib) mkOption mkEnableOption types;
in
{
  options.provisioner.docker = {
    enable = mkEnableOption "Docker provisioner (Talos-in-Docker)";

    clusterName = mkOption {
      type = types.str;
      default = "catallaxy-${config.cluster.name}";
      description = "Docker cluster name";
    };

    waitTimeout = mkOption {
      type = types.str;
      default = "10m";
      description = "Timeout waiting for cluster to be ready";
    };

    colima = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Use Colima on macOS (auto-detected, ignored on Linux)";
      };

      profile = mkOption {
        type = types.str;
        default = "catallaxy";
        description = "Colima profile name (isolates from other VMs)";
      };

      cpu = mkOption {
        type = types.int;
        default = 4;
        description = "Number of CPUs for the VM";
      };

      memory = mkOption {
        type = types.int;
        default = 8;
        description = "Memory in GiB for the VM";
      };

      disk = mkOption {
        type = types.int;
        default = 60;
        description = "Disk size in GiB for the VM";
      };
    };
  };
}

# Deployment phases — declarative ordering and behavior for manifest deployment.
# Components are grouped into phases; each phase carries metadata that controls
# how the CLI (or GitOps engine) applies the manifests.
# Each phase has a number of bundles. A bundle is a finer grained group of k8s resources.

{ config, lib, ... }:

let
  inherit (lib) mkOption types mkDefault;
  k8sLib = import ../lib/kubernetes/types.nix {
    inherit lib;
    k8sVersion = config.cluster.kubernetes.version;
  };

  phaseType = types.submodule {
    options = {
      order = mkOption {
        type = types.int;
        description = "Numeric ordering (lower = deployed earlier)";
      };

      dependsOn = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Phases that must complete before this one";
      };

      keepResources = mkOption {
        type = types.bool;
        default = false;
        description = "Prevent deletion of resources in this phase";
      };

      pruneStrategy = mkOption {
        type = types.enum [
          "default"
          "never"
          "orphan"
        ];
        default = "default";
        description = ''
          Resource pruning behavior:
          - default: normal prune
          - never: never prune
          - orphan: orphan on deletion
        '';
      };

      waitForReady = mkOption {
        type = types.bool;
        default = true;
        description = "Wait for all resources to become ready";
      };

      timeout = mkOption {
        type = types.str;
        default = "10m";
        description = "Timeout for this phase's deployment";
      };

      waitForCRDs = mkOption {
        type = types.bool;
        default = false;
        description = "Wait for CRDs to be established before deploying this phase";
      };

      crdNames = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "CRD names to wait for (used when waitForCRDs = true)";
      };

      bundles = mkOption {
        type = types.attrsOf k8sLib.bundleType;
        default = { };
        description = "Set of bundles that belong in this phase.";
      };
    };
  };
in
{
  options = {
    phases = mkOption {
      type = types.attrsOf phaseType;
      default = { };
      description = ''
        Not all kubernetes resources can be installed at once. There is an ordering to it. 
        Phases are the mechanism to declare that a bundle has a dependency on another.
      '';
    };
  };

  config.phases = {
    crds = {
      order = mkDefault (-10);
      waitForReady = mkDefault true;
      timeout = mkDefault "5m";
    };

    namespaces = {
      order = mkDefault (-5);
      dependsOn = mkDefault [ "crds" ];
      waitForReady = mkDefault true;
      timeout = mkDefault "5m";
    };

    networking = {
      order = mkDefault 0;
      dependsOn = mkDefault [ "namespaces" ];
      waitForReady = mkDefault true;
      timeout = mkDefault "10m";
    };

    operators = {
      order = mkDefault 10;
      dependsOn = mkDefault [ "networking" ];

      waitForReady = mkDefault true;
      timeout = mkDefault "10m";
    };

    secrets = {
      order = mkDefault 20;
      dependsOn = mkDefault [ "operators" ];
      waitForReady = mkDefault true;
      timeout = mkDefault "5m";
    };

    infrastructure = {
      order = mkDefault 30;
      dependsOn = mkDefault [
        "operators"
        "secrets"
      ];
      waitForReady = mkDefault true;
      timeout = mkDefault "10m";
    };

    gitops = {
      order = mkDefault 40;
      dependsOn = mkDefault [
        "operators"
        "secrets"
      ];
      waitForReady = mkDefault true;
      timeout = mkDefault "5m";
    };

    databases = {
      order = mkDefault 50;
      dependsOn = mkDefault [
        "operators"
        "secrets"
      ];
      waitForReady = mkDefault true;
      timeout = mkDefault "10m";
    };

    apps = {
      order = mkDefault 90;
      dependsOn = mkDefault [
        "infrastructure"
        "databases"
      ];
      waitForReady = mkDefault true;
      timeout = mkDefault "10m";
    };

    workloads = {
      order = mkDefault 100;
      dependsOn = mkDefault [
        "infrastructure"
        "databases"
      ];
      waitForReady = mkDefault true;
      timeout = mkDefault "5m";
    };
  };
}

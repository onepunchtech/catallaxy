# `lab.out` is what a lab exposes to everything outside the module system:
# the CLI, the flake, and the checks. It was one 606-line file; the three
# widest outputs have their own now and this holds the small ones.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkOption types;
  renderers = import ../../../lib/render { inherit lib pkgs; };
in
{
  imports = [
    ./cli-config.nix
    ./manifests.nix
    ./package.nix
    ./sbom.nix
  ];

  options.lab.out = {
    allClusters = mkOption {
      type = types.attrsOf types.attrs;
      readOnly = true;
      internal = true;
      description = ''
        Computed attrset of all clusters in the lab.
        Keys are cluster names, values are evaluated cluster configs.
        Use this for cross-cluster references.
      '';
    };

    clusterNames = mkOption {
      type = types.listOf types.str;
      readOnly = true;
      internal = true;
      description = "List of all cluster names in the lab";
    };

    shell = mkOption {
      type = types.attrs;
      readOnly = true;
      internal = true;
      description = "Dev-shell inputs for this lab (packages + variables).";
    };

    runtimeContexts = mkOption {
      type = types.attrsOf types.str;
      readOnly = true;
      internal = true;
      description = ''
        Per-cluster kubectl context an operator should use RIGHT NOW.
        Distinct from cluster.ref.kubeContext, which is provisioner-
        baked (e.g. k3d-<lab>-<cluster> for k3d, or
        <contextPrefix>-<cluster> for Crossplane targets).
        Post-pivot for a Crossplane-provisioned cluster (self-
        provisioning or otherwise), the runtime context is the
        bare cluster-name alias that sync-kubeconfig installs; the
        Nix-baked provisioner context is either stale (destroyed k3d
        bootstrap) or never existed (DOKS never got the prefixed
        name). This attrset flattens the resolution: consumers look
        up by cluster name, get the right context regardless of
        whether the cluster is pivoted, local, or external.

        Populated by the planner from provisionerGraph. Callers
        outside the planner (CLI, ops commands, lifecycle hooks)
        should prefer this over cluster.ref.kubeContext.
      '';
    };

    labNamespaces = mkOption {
      type = types.attrsOf (types.listOf types.str);
      readOnly = true;
      internal = true;
      description = ''
        Per-cluster list of lab-created namespaces (before prefix application).
        Used by checks to verify prefix completeness.
      '';
    };

    verifyTests = mkOption {
      type = types.attrsOf types.package;
      readOnly = true;
      internal = true;
      description = ''
        Per-cluster Chainsaw Test packages, linked into the lab package at
        `verify/<cluster>/`. `cata lab verify` runs them against that
        cluster's runtime context.
      '';
    };

  };

  config.lab.out = {
    allClusters = config.lab.clusters;

    shell = {
      packages = lib.unique (
        lib.concatMap (c: c.shell.packages or [ ]) (lib.attrValues config.lab.out.allClusters)
      );
      variables = {
        CATALLAXY_LAB = config.lab.name;
        CATALLAXY_FLAKE = ".#${config.lab.name}";
      };
    };

    clusterNames = lib.attrNames config.lab.out.allClusters;

    labNamespaces = lib.mapAttrs (
      name: clusterCfg:
      lib.unique (lib.concatMap (b: b.createNamespaces) (lib.attrValues clusterCfg.bundles))
    ) config.lab.out.allClusters;

    verifyTests = lib.mapAttrs (
      name: clusterCfg:
      renderers.chainsaw.mkVerifyTest {
        labName = config.lab.name;
        clusterName = name;
        checks = clusterCfg.verify.out.checks;
      }
    ) config.lab.out.allClusters;

  };
}

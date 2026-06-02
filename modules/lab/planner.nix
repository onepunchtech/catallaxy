# Deployment planner — computes an ordered deployment plan from lab topology.
#
# The plan is a list of steps that the CLI executes sequentially.
# Each step has a `type` field and type-specific data.
# This keeps orchestration logic in Nix (declarative, inspectable)
# and the CLI as a dumb step executor.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkOption
    types
    mapAttrsToList
    filter
    flatten
    sort
    ;

  cfg = config.lab;
  clusters = cfg.out.allClusters;

  # Categorize clusters by provisioner
  clustersByProvisioner = provisioner:
    filter (c: c.provisioner == provisioner) (
      mapAttrsToList (
        name: clusterCfg: {
          inherit name;
          provisioner = clusterCfg.cluster.provisioner;
          config = clusterCfg;
        }
      ) clusters
    );

  localClusters = clustersByProvisioner "k3d" ++ clustersByProvisioner "talos";
  externalClusters = clustersByProvisioner "external";
  crossplaneClusters = clustersByProvisioner "crossplane";

  needsBootstrap = crossplaneClusters != [ ];

  # Find the management cluster (has crossplane enabled for provisioning)
  mgmtCluster =
    let
      candidates = filter (
        c: (c.config.components.crossplane.enable or false)
      ) localClusters;
    in
    if candidates != [ ] then builtins.head candidates else null;

  # ── Plan computation ──────────────────────────────────────────────────

  # Step: create infrastructure services (DNS, registry, ingress)
  serviceSteps =
    if cfg.out.cliConfig.services != { } then
      [
        {
          type = "setup-services";
          description = "Start lab infrastructure services";
        }
      ]
    else
      [ ];

  # Steps: create local clusters
  createLocalSteps = map (
    c: {
      type = "create-cluster";
      description = "Create ${c.provisioner} cluster '${c.name}'";
      name = c.name;
      provisioner = c.provisioner;
      ephemeral = false;
    }
  ) localClusters;

  # Step: ensure secrets exist before deploying (when lab has managed secrets)
  secretsSteps =
    let
      hasSecrets = (cfg.secrets.managed or { }) != { };
      storeNames = lib.attrNames (cfg.secrets.stores or { });
    in
    if hasSecrets then
      [
        {
          type = "ensure-secrets";
          description = "Ensure lab secrets are generated and available";
          stores = storeNames;
        }
      ]
    else
      [ ];

  # Steps: deploy manifests to local clusters
  deployLocalSteps = map (
    c: {
      type = "deploy-manifests";
      description = "Deploy manifests to '${c.name}'";
      target = c.name;
    }
  ) localClusters;

  # Steps for crossplane-provisioned clusters
  crossplaneSteps =
    if crossplaneClusters == [ ] then
      [ ]
    else
      let
        clusterNames = map (c: c.name) crossplaneClusters;
        waitResources = map (
          c: {
            name = c.name;
          }
        ) crossplaneClusters;
      in
      [
        # Wait for crossplane to provision the clusters
        {
          type = "wait-for-resources";
          description = "Wait for Crossplane to provision cloud clusters";
          target = if mgmtCluster != null then mgmtCluster.name else (builtins.head localClusters).name;
          resources = waitResources;
        }
        # Sync kubeconfigs (via DO API from mgmt cluster)
        {
          type = "sync-kubeconfig";
          description = "Sync kubeconfigs for cloud clusters";
          target = if mgmtCluster != null then mgmtCluster.name else (builtins.head localClusters).name;
          clusters = clusterNames;
        }
      ]
      # Deploy manifests to each provisioned cluster
      ++ map (
        c: {
          type = "deploy-manifests";
          description = "Deploy manifests to '${c.name}'";
          target = c.name;
        }
      ) crossplaneClusters;

  # Assemble the full plan
  fullPlan =
    serviceSteps
    ++ createLocalSteps
    ++ secretsSteps
    ++ deployLocalSteps
    ++ crossplaneSteps;

  # ── Teardown plan (reverse of deployment) ──────────────────────────────

  # Clusters with teardown hooks (mgmt with crossplane, CAPI, etc.)
  clustersWithHooks = filter (
    c: (c.config.lifecycle.teardown or [ ]) != [ ]
  ) localClusters;

  # Non-mgmt local clusters (destroyed before mgmt)
  nonMgmtLocalClusters = filter (
    c: mgmtCluster == null || c.name != mgmtCluster.name
  ) localClusters;

  # Step: run teardown hooks for clusters that have them (mgmt first via ordering)
  teardownHookSteps = map (
    c: {
      type = "teardown-hooks";
      description = "Run teardown hooks for '${c.name}'";
      target = c.name;
    }
  ) clustersWithHooks;

  # Step: destroy crossplane-provisioned clusters (no-op, already cleaned up by hooks)
  destroyCrossplaneSteps = map (
    c: {
      type = "destroy-cluster";
      description = "Remove '${c.name}' (${c.provisioner}-provisioned)";
      name = c.name;
    }
  ) crossplaneClusters;

  # Step: destroy non-mgmt local clusters
  destroyNonMgmtSteps = map (
    c: {
      type = "destroy-cluster";
      description = "Destroy ${c.provisioner} cluster '${c.name}'";
      name = c.name;
    }
  ) nonMgmtLocalClusters;

  # Step: destroy mgmt cluster last (after crossplane cleanup)
  destroyMgmtSteps =
    if mgmtCluster != null then
      [
        {
          type = "destroy-cluster";
          description = "Destroy ${mgmtCluster.provisioner} cluster '${mgmtCluster.name}'";
          name = mgmtCluster.name;
        }
      ]
    else
      [ ];

  # Step: remove infrastructure services
  removeServiceSteps =
    if cfg.out.cliConfig.services != { } then
      [
        {
          type = "remove-services";
          description = "Remove lab infrastructure services";
        }
      ]
    else
      [ ];

  # Step: remove Docker network
  removeNetworkSteps = [
    {
      type = "remove-network";
      description = "Remove lab Docker network";
    }
  ];

  # Step: remove CA trust
  removeTrustSteps = [
    {
      type = "remove-trust";
      description = "Remove lab CA from browser trust store";
    }
  ];

  teardownPlan =
    teardownHookSteps
    ++ destroyCrossplaneSteps
    ++ destroyNonMgmtSteps
    ++ destroyMgmtSteps
    ++ removeServiceSteps
    ++ removeNetworkSteps
    ++ removeTrustSteps;

in
{
  options.lab.out = {
    deploymentPlan = mkOption {
      type = types.listOf types.attrs;
      readOnly = true;
      description = ''
        Computed deployment plan — an ordered list of steps for the CLI to execute.
        Each step has a `type` field and type-specific data.
        Inspect with `cata lab plan`.
      '';
    };

    teardownPlan = mkOption {
      type = types.listOf types.attrs;
      readOnly = true;
      description = ''
        Computed teardown plan — an ordered list of steps for safe lab destruction.
        Ensures cloud resources are cleaned up before local clusters are destroyed.
        Inspect with `cata lab plan --teardown`.
      '';
    };
  };

  config.lab.out = {
    deploymentPlan = fullPlan;
    teardownPlan = teardownPlan;
  };
}

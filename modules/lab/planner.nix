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

  # Find the management cluster (has crossplane or CAPI enabled for provisioning)
  mgmtCluster =
    let
      candidates = filter (
        c: (c.config.components.crossplane.enable or false)
            || (c.config.components.cluster-api.enable or false)
      ) localClusters;
    in
    if candidates != [ ] then builtins.head candidates else null;

  # Detect self-provisioning clusters: a local cluster that runs a provisioner
  # which creates a cloud cluster with the same name. This implies bootstrap + pivot.
  selfProvisioningClusters = filter (
    c:
    let
      xpClusterNames = lib.attrNames (
        c.config.components.crossplane.digitalocean.kubernetesClusters or { }
      );
      capiClusterNames = lib.attrNames (
        c.config.components.cluster-api.clusters or { }
      );
      provisionedNames = xpClusterNames ++ capiClusterNames;
    in
    builtins.elem c.name provisionedNames
  ) localClusters;

  # Non-self-provisioning crossplane clusters (deployed after pivot)
  nonSelfCrossplaneClusters = filter (
    c: !(lib.any (sp: sp.name == c.name) selfProvisioningClusters)
  ) crossplaneClusters;

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

  # All cloud-provisioned cluster names: explicit crossplane clusters + self-provisioning clusters
  allCloudClusterNames =
    (map (c: c.name) crossplaneClusters)
    ++ (map (c: c.name) selfProvisioningClusters);

  # Steps for crossplane/CAPI-provisioned clusters
  crossplaneSteps =
    if allCloudClusterNames == [ ] then
      [ ]
    else
      let
        waitResources = map (name: { inherit name; }) allCloudClusterNames;
        mgmtTarget = if mgmtCluster != null then mgmtCluster.name else (builtins.head localClusters).name;
      in
      [
        {
          type = "wait-for-resources";
          description = "Wait for Crossplane to provision cloud clusters";
          target = mgmtTarget;
          resources = waitResources;
        }
        {
          type = "sync-kubeconfig";
          description = "Sync kubeconfigs for cloud clusters";
          target = mgmtTarget;
          clusters = allCloudClusterNames;
        }
      ];

  # Pivot steps for self-provisioning clusters
  pivotSteps = map (
    c:
    let
      hasXp = c.config.components.crossplane.enable or false;
      hasCapi = c.config.components.cluster-api.enable or false;
      provisioner = if hasXp then "crossplane" else if hasCapi then "capi" else "unknown";
      bootstrapContext = c.config.cluster.ref.kubeContext;
    in
    {
      type = "pivot";
      description = "Migrate '${c.name}' from bootstrap to cloud";
      cluster = c.name;
      bootstrapContext = bootstrapContext;
      targetContext = c.name;
      inherit provisioner;
      skipIfReachable = c.name;
    }
  ) selfProvisioningClusters;

  # Deploy manifests to non-self-provisioning cloud clusters (after pivot)
  deployCloudSteps = map (
    c: {
      type = "deploy-manifests";
      description = "Deploy manifests to '${c.name}'";
      target = c.name;
    }
  ) nonSelfCrossplaneClusters;

  # Assemble the full plan
  fullPlan =
    serviceSteps
    ++ createLocalSteps
    ++ secretsSteps
    ++ deployLocalSteps
    ++ crossplaneSteps
    ++ pivotSteps
    ++ deployCloudSteps;

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

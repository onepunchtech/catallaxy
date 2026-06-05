# Deployment planner — computes an ordered deployment plan from lab topology.
#
# The plan is a list of typed steps that the CLI executes sequentially.
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
    concatMap
    map
    ;

  cfg = config.lab;
  clusters = cfg.out.allClusters;

  # ── Step type ────────────────────────────────────────────────────────────
  # A single union type — all fields optional, each step type uses what it needs.
  stepType = types.submodule {
    options = {
      type = mkOption { type = types.str; };
      description = mkOption {
        type = types.str;
        default = "";
      };
      name = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      target = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      provisioner = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      ephemeral = mkOption {
        type = types.bool;
        default = false;
      };
      stores = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
      resources = mkOption {
        type = types.listOf (types.attrsOf types.str);
        default = [ ];
      };
      clusters = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
      cluster = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      bootstrapContext = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      targetContext = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      skipIfReachable = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
    };
  };

  # ── Cluster categorization ──────────────────────────────────────────────

  allClusters = mapAttrsToList (name: clusterCfg: {
    inherit name;
    provisioner = clusterCfg.cluster.provisioner;
    config = clusterCfg;
  }) clusters;

  clustersByProvisioner = provisioner: filter (c: c.provisioner == provisioner) allClusters;

  localClusters = clustersByProvisioner "k3d" ++ clustersByProvisioner "talos";
  crossplaneClusters = clustersByProvisioner "crossplane";
  crossplaneClusterNames = map (c: c.name) crossplaneClusters;

  # ── Provisioner graph ───────────────────────────────────────────────────
  # For each local cluster that runs a provisioner, find which cloud clusters it provisions.

  provisionerGraph =
    map
      (
        c:
        let
          xpClusterNames = lib.attrNames (
            c.config.components.crossplane.digitalocean.kubernetesClusters or { }
          );
          capiClusterNames = lib.attrNames (c.config.components.cluster-api.clusters or { });
          allProvisioned = xpClusterNames ++ capiClusterNames;
          # Only include clusters that actually exist in the lab as cloud-provisioned
          targets = filter (name: builtins.elem name crossplaneClusterNames || name == c.name) allProvisioned;
          # Self-provisioning: this cluster provisions a cloud version of itself
          isSelfProvisioning = builtins.elem c.name allProvisioned;
          hasXp = c.config.components.crossplane.enable or false;
          hasCapi = c.config.components.cluster-api.enable or false;
        in
        {
          source = c;
          inherit targets isSelfProvisioning;
          provisioner =
            if hasXp then
              "crossplane"
            else if hasCapi then
              "capi"
            else
              "unknown";
        }
      )
      (
        filter (
          c:
          (c.config.components.crossplane.enable or false)
          || (c.config.components.cluster-api.enable or false)
        ) localClusters
      );

  # Clusters that are provisioned by any provisioner (union of all targets)
  allProvisionedNames = lib.unique (concatMap (e: e.targets) provisionerGraph);

  # Clusters provisioned by someone else (not self-provisioning, deployed after pivot)
  nonSelfProvisionedClusters = filter (
    c:
    builtins.elem c.name allProvisionedNames
    && !(lib.any (e: e.isSelfProvisioning && e.source.name == c.name) provisionerGraph)
  ) crossplaneClusters;

  # ── Deployment plan steps ───────────────────────────────────────────────

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

  createLocalSteps = map (c: {
    type = "create-cluster";
    description = "Create ${c.provisioner} cluster '${c.name}'";
    name = c.name;
    provisioner = c.provisioner;
  }) localClusters;

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

  deployLocalSteps = map (c: {
    type = "deploy-manifests";
    description = "Deploy manifests to '${c.name}'";
    target = c.name;
  }) localClusters;

  # Per-provisioner steps: wait → sync-kubeconfig → pivot → deploy targets
  provisionSteps = concatMap (
    entry:
    if entry.targets == [ ] then
      [ ]
    else
      [
        {
          type = "wait-for-resources";
          description = "Wait for ${entry.provisioner} to provision clusters from '${entry.source.name}'";
          target = entry.source.name;
          resources = map (name: { inherit name; }) entry.targets;
        }
        {
          type = "sync-kubeconfig";
          description = "Sync kubeconfigs for clusters provisioned by '${entry.source.name}'";
          target = entry.source.name;
          clusters = entry.targets;
        }
      ]
      # Pivot for self-provisioning clusters
      ++ lib.optionals entry.isSelfProvisioning [
        {
          type = "pivot";
          description = "Migrate '${entry.source.name}' from bootstrap to cloud";
          cluster = entry.source.name;
          bootstrapContext = entry.source.config.cluster.ref.kubeContext;
          targetContext = entry.source.name;
          provisioner = entry.provisioner;
          skipIfReachable = entry.source.name;
        }
      ]
      # Deploy manifests to non-self targets
      ++ map (name: {
        type = "deploy-manifests";
        description = "Deploy manifests to '${name}'";
        target = name;
      }) (filter (name: name != entry.source.name) entry.targets)
  ) provisionerGraph;

  fullPlan = serviceSteps ++ createLocalSteps ++ secretsSteps ++ deployLocalSteps ++ provisionSteps;

  # ── Teardown plan ───────────────────────────────────────────────────────

  # Clusters with teardown hooks
  clustersWithHooks = filter (c: (c.config.lifecycle.teardown or [ ]) != [ ]) localClusters;

  # Provisioning clusters destroyed last (they run teardown hooks first)
  provisioningClusterNames = map (e: e.source.name) provisionerGraph;
  nonProvisioningLocalClusters = filter (
    c: !(builtins.elem c.name provisioningClusterNames)
  ) localClusters;
  provisioningLocalClusters = filter (c: builtins.elem c.name provisioningClusterNames) localClusters;

  teardownHookSteps = map (c: {
    type = "teardown-hooks";
    description = "Run teardown hooks for '${c.name}'";
    target = c.name;
  }) clustersWithHooks;

  destroyCrossplaneSteps = map (c: {
    type = "destroy-cluster";
    description = "Remove '${c.name}' (${c.provisioner}-provisioned)";
    name = c.name;
  }) crossplaneClusters;

  destroyNonProvisioningSteps = map (c: {
    type = "destroy-cluster";
    description = "Destroy ${c.provisioner} cluster '${c.name}'";
    name = c.name;
  }) nonProvisioningLocalClusters;

  destroyProvisioningSteps = map (c: {
    type = "destroy-cluster";
    description = "Destroy ${c.provisioner} cluster '${c.name}'";
    name = c.name;
  }) provisioningLocalClusters;

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

  teardownPlan =
    teardownHookSteps
    ++ destroyCrossplaneSteps
    ++ destroyNonProvisioningSteps
    ++ destroyProvisioningSteps
    ++ removeServiceSteps
    ++ [
      {
        type = "remove-network";
        description = "Remove lab Docker network";
      }
      {
        type = "remove-trust";
        description = "Remove lab CA from browser trust store";
      }
    ];

in
{
  options.lab.out = {
    deploymentPlan = mkOption {
      type = types.listOf stepType;
      readOnly = true;
      description = ''
        Computed deployment plan — an ordered list of typed steps for the CLI to execute.
        Inspect with `cata lab plan`.
      '';
    };

    teardownPlan = mkOption {
      type = types.listOf stepType;
      readOnly = true;
      description = ''
        Computed teardown plan — an ordered list of typed steps for safe lab destruction.
        Inspect with `cata lab plan --teardown`.
      '';
    };
  };

  config.lab.out = {
    deploymentPlan = fullPlan;
    inherit teardownPlan;
  };
}

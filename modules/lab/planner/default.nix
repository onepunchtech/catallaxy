{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkOption types;

  inherit (import ./types.nix { inherit lib; }) plannedStepType declaredStepType;
  kinds = import ./kinds { inherit lib; };
  tokens = import ../../../lib/plan-tokens.nix { inherit lib; };

  originName = name: step: if step.origin == null then "lab.steps.${name}" else step.origin;

  kindlessSteps = lib.concatLists (
    lib.mapAttrsToList (
      name: step: lib.optional (step.kind == null) "  ${originName name step}"
    ) config.lab.steps
  );

  wrongDirection = lib.concatLists (
    lib.mapAttrsToList (
      name: step:
      let
        allowed = kinds.${step.kind}.directions;
        wanted = if step.direction == "both" then allowed else [ step.direction ];
        unsupported = lib.subtractLists allowed wanted;
      in
      lib.optional (step.kind != null && unsupported != [ ]) (
        "  ${originName name step} (kind '${step.kind}', direction '${step.direction}') "
        + "cannot run in: ${lib.concatStringsSep ", " unsupported}"
      )
    ) config.lab.steps
  );

  cfg = config.lab;
  clusters = cfg.out.allClusters;
  graph = (import ../../../lib/eval/deployment-graph.nix { inherit lib; }).computeGraph clusters;
  inherit (graph) syncedContextClusterNames;

  deploySteps = (import ../../../lib/eval/deployment-plan.nix { inherit lib; }).mkSteps {
    inherit cfg config graph;
  };
  teardownSteps = (import ../../../lib/eval/teardown-plan.nix { inherit lib; }).mkTeardownPlan {
    inherit cfg graph;
  };

  clusterSteps = lib.concatMapAttrs (
    clusterName: clusterCfg:
    lib.mapAttrs' (
      stepName: step:
      lib.nameValuePair "${clusterName}-${stepName}" (
        (removeAttrs step [ "scope" ])
        // {
          origin = if step.origin != null then step.origin else "clusters.${clusterName}.steps.${stepName}";
          cluster = if step.scope == "cluster" then clusterName else null;
        }
      )
    ) clusterCfg.steps
  ) clusters;

  frameworkSteps = deploySteps // teardownSteps;

  foldedNames = lib.concatMap (
    clusterName:
    map (stepName: "${clusterName}-${stepName}") (lib.attrNames clusters.${clusterName}.steps)
  ) (lib.attrNames clusters);
  aliasedFoldedNames = lib.filter (n: lib.count (m: m == n) foldedNames > 1) (lib.unique foldedNames);
  shadowedFrameworkNames = lib.intersectLists (lib.attrNames clusterSteps) (
    lib.attrNames frameworkSteps
  );

  planGraph = import ../../../lib/eval/plan-graph.nix { inherit lib; };
  graphLib = import ../../../lib/eval/graph.nix { inherit lib; };

  stepsFor =
    direction:
    lib.mapAttrs (_: withDerivedAnchors) (
      lib.filterAttrs (_: s: s.direction == direction || s.direction == "both") config.lab.steps
    );

  withDerivedAnchors =
    s:
    s
    // lib.optionalAttrs kinds.${s.kind}.dialsLabEndpoints {
      after = s.after ++ [ (tokens.wants tokens.lab.reachable) ];
    };

  derivedKubeContext =
    s:
    lib.optionalAttrs (s.cluster != null && (s.params.kubeContext or null) == null) {
      kubeContext = config.lab.out.runtimeContexts.${s.cluster} or null;
    };

  lowerStep = s: {
    inherit (s)
      name
      kind
      description
      cluster
      ;
    origin = originName s.name s;
    policy = s.policy // {
      retry = kinds.${s.kind}.idempotency;
    };
    params = s.params // lib.optionalAttrs (s.params ? kubeContext) (derivedKubeContext s);
  };

  computePlan =
    direction:
    let
      steps = stepsFor direction;
      sorted = planGraph.topoSort { inherit steps; };
    in
    map lowerStep sorted;

  stepConflicts = lib.concatMap (direction: planGraph.conflictErrors (stepsFor direction)) [
    "deploy"
    "teardown"
  ];

  deploySteps' = stepsFor "deploy";
  deployEdges = planGraph.buildEdges deploySteps';
  deployProvidesIdx = planGraph.buildProvidesIdx deploySteps';

  applyStepsFor =
    clusterName:
    lib.attrNames (
      lib.filterAttrs (
        _: s: s.kind == "deploy-manifests" && (s.params.target or null) == clusterName
      ) deploySteps'
    );

  precedingApply =
    clusterName:
    let
      applies = applyStepsFor clusterName;
    in
    lib.unique (
      lib.concatMap (
        a:
        lib.filter (n: n != a) (
          graphLib.closureFrom {
            edges = deployEdges;
            roots = [ a ];
          }
        )
      ) applies
    );

  bridgeErrors = lib.concatLists (
    lib.mapAttrsToList (
      clusterName: clusterCfg:
      let
        applies = applyStepsFor clusterName;
        before = precedingApply clusterName;
      in
      lib.concatMap (
        req:
        let
          providers = deployProvidesIdx.${req.token} or [ ];
          late = lib.subtractLists before providers;
        in
        if providers == [ ] then
          lib.optional req.hard ''
            clusters.${clusterName}.bundles.${req.bundle}: ${req.field} names
            'step:${req.token}', which no step in the deploy plan publishes.

            Declare a step with `provides = [ "${req.token}" ]`, or write it as
            'optional:step:${req.token}' if it is allowed to match nothing.
          ''
        else if applies == [ ] then
          [ ]
        else
          let
            publishers = lib.concatStringsSep " and " (map (n: "'${n}'") late);
            appliers = lib.concatStringsSep " or " (map (n: "'${n}'") applies);
            verb = if lib.length late == 1 then "that step does" else "those steps do";
          in
          lib.optional (late != [ ]) ''
            clusters.${clusterName}.bundles.${req.bundle}: ${req.field} names
            'step:${req.token}', which ${publishers} publishes, and ${verb} not
            run before ${appliers}.

            This cluster's manifests are all applied by that one step, so a
            token published after it is published after this bundle has already
            been installed. The edge would read as ordering and do nothing.

            Move the step earlier by having it publish something ${appliers}
            waits on, or drop the requirement.
          ''
      ) clusterCfg.cluster.out.stepRequirements
    ) clusters
  );

in
{
  options.lab.steps = mkOption {
    type = types.attrsOf declaredStepType;
    default = { };
    description = ''
      The lab's step DAG. Framework emitters, floes, aspects, and labs
      all contribute entries here. `after` / `before` / `requires` /
      `provides` declare ordering; `plan-graph.topoSort` resolves the
      DAG and lowers each step into `lab.out.{deploymentPlan,teardownPlan}`.
    '';
  };

  options.lab.out = {
    deploymentPlan = mkOption {
      type = types.listOf plannedStepType;
      readOnly = true;
      internal = true;
      description = ''
        Ordered deployment steps for the CLI. Derived from
        `lab.steps` (direction ∈ {deploy, both}) via topological sort.
      '';
    };

    teardownPlan = mkOption {
      type = types.listOf plannedStepType;
      readOnly = true;
      internal = true;
      description = ''
        Ordered teardown steps for the CLI. Derived from
        `lab.steps` (direction ∈ {teardown, both}) via topological sort.
      '';
    };
  };

  config.lab.steps = frameworkSteps // clusterSteps;

  config.lab.assertions =
    (map (message: {
      assertion = false;
      inherit message;
    }) (stepConflicts ++ bridgeErrors))
    ++ [
      {
        assertion = aliasedFoldedNames == [ ];
        message = ''
          Two clusters contribute steps whose folded `<cluster>-<name>` keys
          collide: ${lib.concatStringsSep ", " aliasedFoldedNames}.
          One of them would silently replace the other in the plan. Rename
          the step on one of the clusters.
        '';
      }
      {
        assertion = kindlessSteps == [ ];
        message = ''
          Steps declare no kind:
          ${lib.concatStringsSep "\n" kindlessSteps}
          The kind selects the type of `params` and the executor that runs the
          step. Valid kinds are the entries in modules/lab/planner/kinds/.
        '';
      }
      {
        assertion = wrongDirection == [ ];
        message = ''
          Steps declare a direction their kind cannot run in:
          ${lib.concatStringsSep "\n" wrongDirection}
          The executor would abort part-way through the plan, after every step
          ahead of this one had already run. Change `direction`, or the kind.
        '';
      }
      {
        assertion = shadowedFrameworkNames == [ ];
        message = ''
          Cluster-declared steps shadow framework-emitted ones:
          ${lib.concatStringsSep ", " shadowedFrameworkNames}.
          Rename the cluster step; the framework's own emitters own those
          keys, and the plan would run the cluster's step in its place.
        '';
      }
    ];

  config.lab.out = {
    deploymentPlan = computePlan "deploy";
    teardownPlan = computePlan "teardown";

    runtimeContexts = lib.mapAttrs (
      name: c: if builtins.elem name syncedContextClusterNames then name else c.cluster.ref.kubeContext
    ) config.lab.clusters;
  };
}

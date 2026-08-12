{ lib }:

let
  inherit (lib)
    concatMap
    filter
    map
    mapAttrsToList
    mergeAttrsList
    nameValuePair
    optionalAttrs
    ;
  tokens = import ../plan-tokens.nix { inherit lib; };
  inherit (tokens) needs wants;
in
{
  mkTeardownPlan =
    { cfg, graph }:
    let
      inherit (graph)
        allClusters
        localClusters
        provisionerGraph
        syncedContextFor
        ;

      awaitCleanup = wants tokens.lab.cleanup;

      cloudDestroyFor =
        entry:
        let
          selfName = entry.source.name;
          selfCtx = syncedContextFor selfName;
          declared = entry.source.config.cluster.provisions;

          deletable = filter (t: declared.${t}.resourceKind != null) entry.targets;
          nonSelfTargets = filter (t: t != selfName) deletable;

          releaseStep = target: {
            "release-${target}-cloud" = {
              kind = "release-cluster-cloud-resources";
              direction = "teardown";
              after = [ awaitCleanup ];
              provides = [ (tokens.cluster target).cloudReleased ];
              params = {
                inherit target;

                kubeContext = target;
                waitTimeoutSeconds = 300;
              };
              description = "Release LoadBalancers and Volumes on '${target}' via CCM/CSI";
            };
          };

          deleteMRStep = target: waitFlag: {
            "delete-mr-${target}" = {
              kind = "delete-managed-resource";
              direction = "teardown";
              after = [ (needs (tokens.cluster target).cloudReleased) ];
              provides = [ (tokens.cluster target).managedResourceDeleted ];
              params = {
                inherit target;
                inherit (declared.${target}) resourceKind resourceName;

                kubeContext = selfCtx;
                wait = waitFlag;
                waitTimeoutSeconds = cfg.timeouts.waitForResources;
              }
              // optionalAttrs (declared.${target}.externalNameDiscoveryBin != null) {
                inherit (declared.${target}) externalNameDiscoveryBin;
              };
              description = "Delete ${
                declared.${target}.resourceKind
              }/${target}: its controller fires the cloud destroy";
            };
          };

          waitGoneStep = target: {
            "wait-cluster-gone-${target}" = {
              kind = "wait-for-cluster-gone";
              direction = "teardown";
              after = [
                (needs (tokens.cluster target).managedResourceDeleted)
              ]
              ++ (map (t: needs (tokens.cluster t).managedResourceDeleted) nonSelfTargets);
              provides = [ (tokens.cluster target).gone ];
              params = {
                inherit target;
                inherit (declared.${target}) resourceKind resourceName;
                kubeContext = selfCtx;
                waitTimeoutSeconds = cfg.timeouts.waitForResources;
              };
              description = "Wait for ${declared.${target}.resourceKind}/${target} to disappear";
            };
          };

          nonSelfSteps = concatMap (t: [
            (releaseStep t)
            (deleteMRStep t true)
          ]) nonSelfTargets;

          selfSteps = lib.optionals (builtins.elem selfName deletable) [
            (releaseStep selfName)
            (deleteMRStep selfName false)
            (waitGoneStep selfName)
          ];
        in
        mergeAttrsList (nonSelfSteps ++ selfSteps);

      cloudDestroySteps = mergeAttrsList (map cloudDestroyFor provisionerGraph);

      provisioningNames = map (e: e.source.name) provisionerGraph;

      destroyNonProvisioning = mergeAttrsList (
        map (c: {
          "destroy-cluster-${c.name}" = {
            kind = "destroy-cluster";
            direction = "teardown";
            after = [ awaitCleanup ];
            provides = [ (tokens.cluster c.name).destroyed ];
            params = {
              name = c.name;
              inherit (c) provisioner;
            };
            description = "Destroy ${c.provisioner} cluster '${c.name}'";
          };
        }) (filter (c: !(builtins.elem c.name provisioningNames)) localClusters)
      );

      destroyProvisioning = mergeAttrsList (
        map (c: {
          "destroy-cluster-bootstrap-${c.name}" = {
            kind = "destroy-cluster";
            direction = "teardown";
            after = [ (wants (tokens.cluster c.name).gone) ];
            provides = [ (tokens.cluster c.name).destroyed ];
            params = {
              name = c.name;
              inherit (c) provisioner;
              skipIfMissing = true;
            };
            description = "Destroy bootstrap ${c.provisioner} cluster '${c.name}' (if still around)";
          };
        }) (filter (c: builtins.elem c.name provisioningNames) localClusters)
      );

      awaitDestroyed = map (c: wants (tokens.cluster c.name).destroyed) localClusters;

      dnsTeardownStep = optionalAttrs (cfg.dns.configureHost && cfg.out.cliConfig.dnsInfo != null) {
        dns-teardown = {
          kind = "dns-teardown";
          direction = "teardown";
          after = [ awaitCleanup ];
          provides = [ tokens.lab.hostDnsRemoved ];
          params.zone = cfg.dns.zone;
          description = "Stop pointing host DNS for '${cfg.dns.zone}' at this lab";
        };
      };

      removeServicesStep = optionalAttrs (cfg.out.cliConfig.services != { }) {
        remove-services = {
          kind = "remove-services";
          direction = "teardown";

          after = [ awaitCleanup ] ++ awaitDestroyed;
          provides = [ tokens.lab.servicesRemoved ];
          description = "Remove lab infrastructure services";
        };
      };

      removeNetworkStep = {
        remove-network = {
          kind = "remove-network";
          direction = "teardown";
          after = [
            (wants tokens.lab.servicesRemoved)
            awaitCleanup
          ]
          ++ awaitDestroyed;
          provides = [ tokens.lab.networkRemoved ];
          description = "Remove lab Docker network";
        };
      };

    in
    mergeAttrsList [
      dnsTeardownStep
      cloudDestroySteps
      destroyNonProvisioning
      destroyProvisioning
      removeServicesStep
      removeNetworkStep
    ];
}

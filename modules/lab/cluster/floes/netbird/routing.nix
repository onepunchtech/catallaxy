{ config, lib, ... }:
let
  cfg = config.floes.netbird;
  nb = import ./lib.nix { inherit lib cfg; };

  inherit (nb)
    apiTokenSecretName
    jwtGroupUuidsSecretName
    owner
    managedBy
    ;

  catalLib = import ../../../../../lib/util/idempotent-job.nix { inherit lib; };

  mkResourcesJson =
    netName: resources:
    builtins.toJSON (
      lib.mapAttrsToList (n: r: {
        name = "${netName}-${n}";
        inherit (r)
          address
          sourceGroups
          description
          enabled
          ;
      }) resources
    );

  netbirdRoutingScript = builtins.readFile ./scripts/routing.sh;

  mkRoutingPodSpec = netName: net: {
    serviceAccountName = "netbird-bootstrap";
    restartPolicy = "OnFailure";
    containers = [
      {
        name = "routing";
        image = cfg.images.bootstrap.ref;
        env = [
          {
            name = "NB_NS";
            value = cfg.namespace;
          }
          {
            name = "NB_URL";
            value = "http://netbird-management.${cfg.namespace}.svc.cluster.local";
          }
          {
            name = "PAT_SECRET";
            value = apiTokenSecretName;
          }
          {
            name = "PAT_KEY";
            value = cfg.operator.apiTokenSecretKey;
          }
          {
            name = "NB_NETWORK_NAME";
            value = netName;
          }
          {

            name = "NB_RESOURCES_JSON";
            value = mkResourcesJson netName net.resources;
          }
          {
            name = "DNS_DOMAINS";
            value = lib.concatStringsSep " " cfg.routing.dnsDomains;
          }
          {
            name = "RESOLVER_IP";
            value = cfg.routing.resolverIP;
          }
          {
            name = "SOURCE_GROUPS";
            value = lib.concatStringsSep " " cfg.routing.sourceGroups;
          }
          {
            name = "ROUTER_GROUP";
            value = net.routerGroup;
          }
          {

            name = "JWT_GROUP_UUIDS_SECRET";
            value = jwtGroupUuidsSecretName;
          }
        ];
        command = [
          "bash"
          "-c"
        ];
        args = [ netbirdRoutingScript ];
      }
    ];
  };

  mkRoutingCronJob = netName: net: {
    "netbird-routing-cron-${netName}" = {
      apiVersion = "batch/v1";
      kind = "CronJob";
      metadata = {
        name = "netbird-routing-${netName}";
        namespace = cfg.namespace;
        labels = managedBy // {
          "app.kubernetes.io/component" = "netbird-routing";
        };
      };
      spec = {
        schedule = "*/2 * * * *";
        concurrencyPolicy = "Forbid";
        successfulJobsHistoryLimit = 1;
        failedJobsHistoryLimit = 3;
        startingDeadlineSeconds = 60;
        jobTemplate = {
          spec = {
            backoffLimit = 2;
            template = {
              metadata.labels = managedBy // {
                "app.kubernetes.io/component" = "netbird-routing";
              };
              spec = (mkRoutingPodSpec netName net) // {
                restartPolicy = "Never";
              };
            };
          };
        };
      };
    };
  };

  netbirdRoutingJobResources =
    if cfg.routing.enable then
      lib.foldl' (
        acc: netName:
        let
          net = cfg.routing.networks.${netName};
        in
        acc // (mkRoutingJob netName net).resources // (mkRoutingCronJob netName net)
      ) { } (lib.attrNames cfg.routing.networks)
    else
      { };

  # Routing is one Job per network, and a label selector cannot say "any
  # of these hashes". So every Job of a given render carries the same
  # generation, derived from the same configuration its individual hashes
  # come from: change anything a routing Job is told and this moves too.
  # It is what lets the readyProbe wait on this render's Jobs rather than
  # on every Job the floe has ever produced.
  routingGeneration = catalLib.hashContent {
    inherit (cfg.routing) networks dnsDomains resolverIP;
  };

  mkRoutingJob =
    netName: net:
    catalLib.mkIdempotentJob {
      name = "netbird-routing-${netName}";
      namespace = cfg.namespace;
      extraLabels = {
        "catallaxy.io/netbird-routing" = "true";
        "catallaxy.io/netbird-routing-generation" = routingGeneration;
      };
      contentInputs = {
        inherit netName;
        inherit (cfg.routing) dnsDomains resolverIP;
        inherit (net) routerGroup;

        resources = mkResourcesJson netName net.resources;
      };
      behaviourVersion = 1;
      podSpec = mkRoutingPodSpec netName net;
    };
in
{
  config = lib.mkIf (cfg.enable && cfg.routing.enable && cfg.operator.enable) {
    floes.netbird.bundles.netbird-routing = {
      inherit owner;
      resources = netbirdRoutingJobResources;

      requires = [
        "netbird/prechart/ready"
        "netbird/management/ready"

        "netbird/api-key/ready"

        "netbird/setup-keys/ready"
      ];

      provides = [ "netbird/routing/ready" ];

      readyProbe = lib.mkIf (cfg.routing.networks != { }) {
        kind = "kubectl-wait";
        args = [
          "--for=condition=complete"
          "job"
          "-l"
          "catallaxy.io/netbird-routing=true,catallaxy.io/netbird-routing-generation=${routingGeneration}"
          "-n"
          cfg.namespace
          "--timeout=5m"
        ];
      };
    };
  };
}
